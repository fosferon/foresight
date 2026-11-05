#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${FORESIGHT_CONSUMER_TMPDIR:-/tmp}/foresight-package-consumer.XXXXXX")"
package_dir="$scratch/foresight_memory"
consumer_dir="$scratch/consumer"

cleanup() {
  if [[ -f "$scratch/postgres/PG_VERSION" ]]; then
    pg_ctl -D "$scratch/postgres" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

cd "$repo_root"
mix hex.build --unpack --output "$package_dir"

mkdir -p "$consumer_dir/lib"

cat >"$consumer_dir/mix.exs" <<'EOF'
defmodule ForesightPackageConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foresight_package_consumer,
      version: "0.0.0",
      elixir: "~> 1.18",
      deps: [{:foresight, path: System.fetch_env!("FORESIGHT_PACKAGE_PATH")}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF

cat >"$consumer_dir/lib/contract.ex" <<'EOF'
defmodule ForesightPackageConsumer.Contract do
  defmodule Repo do
    use Ecto.Repo, otp_app: :foresight_package_consumer, adapter: Ecto.Adapters.Postgres
  end

  defmodule LegacyRepo do
    use Ecto.Repo, otp_app: :foresight_package_consumer, adapter: Ecto.Adapters.Postgres
  end

  def public_contract do
    {
      &Foresight.Migrations.install/2,
      &Foresight.Tenancy.provision_mode_c_schema/4,
      Foresight.Migrations.migrations_path()
    }
  end
end
EOF

cd "$consumer_dir"
FORESIGHT_PACKAGE_PATH="$package_dir" mix deps.get
FORESIGHT_PACKAGE_PATH="$package_dir" mix compile --warnings-as-errors
FORESIGHT_PACKAGE_PATH="$package_dir" mix run --no-start -e '
  {_install, _provision, path} = ForesightPackageConsumer.Contract.public_contract()
  unless File.dir?(path), do: raise("packaged migrations are unavailable")
  unless Foresight.Migrations.Manifest.validate(path) == :ok,
    do: raise("packaged migration manifest is incomplete")
'

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "$scratch/socket"
initdb -D "$scratch/postgres" -A trust -U postgres --encoding UTF8 --locale=C >/dev/null
pg_ctl -D "$scratch/postgres" -l "$scratch/postgres.log" -o "-p $port -k $scratch/socket" -w start >/dev/null
createdb -h "$scratch/socket" -p "$port" -U postgres foresight_consumer
createdb -h "$scratch/socket" -p "$port" -U postgres foresight_legacy

FORESIGHT_PACKAGE_PATH="$package_dir" FORESIGHT_CONSUMER_URL="postgresql://postgres@127.0.0.1:$port/foresight_consumer" \
  FORESIGHT_LEGACY_URL="postgresql://postgres@127.0.0.1:$port/foresight_legacy" \
  mix run --no-start -e '
    alias ForesightPackageConsumer.Contract.Repo
    alias ForesightPackageConsumer.Contract.LegacyRepo
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    Application.put_env(:foresight_package_consumer, Repo,
      url: System.fetch_env!("FORESIGHT_CONSUMER_URL"),
      pool_size: 4,
      types: Foresight.PostgrexTypes
    )
    {:ok, _pid} = Repo.start_link()
    {:ok, %{migrated_versions: control_versions}} = Foresight.Migrations.install(Repo)
    unless length(control_versions) == length(Foresight.Migrations.Manifest.files(:control)),
      do: raise("package control migrations were not installed")
    {:ok, %{migrated_versions: tenant_versions}} =
      Foresight.Tenancy.provision_mode_c_schema(Repo, "package-consumer", "package_consumer",
        rls_enabled: false
      )
    unless length(tenant_versions) == length(Foresight.Migrations.Manifest.files(:tenant)),
      do: raise("package tenant migrations were not installed")
    {:ok, %{migrated_versions: []}} = Foresight.Migrations.install(Repo)
    {:ok, %{migrated_versions: []}} =
      Foresight.Tenancy.provision_mode_c_schema(Repo, "package-consumer", "package_consumer",
        rls_enabled: false
      )

    Application.put_env(:foresight_package_consumer, LegacyRepo,
      url: System.fetch_env!("FORESIGHT_LEGACY_URL"),
      pool_size: 4,
      types: Foresight.PostgrexTypes
    )
    {:ok, _pid} = LegacyRepo.start_link()
    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(LegacyRepo, fn repo ->
        Ecto.Migrator.run(repo, Foresight.Migrations.migrations_path(), :up, all: true)
      end)
    {:ok, %{migrated_versions: []}} = Foresight.Migrations.install(LegacyRepo)
    {:ok, %{rows: [[adopted_count]]}} =
      Ecto.Adapters.SQL.query(LegacyRepo,
        "SELECT count(*) FROM foresight_schema_migrations WHERE migration_name IS NOT NULL AND migration_digest IS NOT NULL",
        []
      )
    unless adopted_count == length(control_versions),
      do: raise("package legacy control migrations were not adopted")
  '
