defmodule Foresight.Migrations do
  @moduledoc """
  Installs Foresight's shared control-plane schema into a consumer database.

  `install/2` accepts the consumer's Repo module and runs only the packaged
  control-plane migrations. Tenant data migrations are deliberately excluded;
  use `Foresight.Tenancy.provision_mode_c_schema/4` for a Mode C tenant schema.

  Foresight records these migrations in `foresight_schema_migrations`, not the
  host application's `schema_migrations` table. The separate ledger prevents a
  host migration with the same integer version from being mistaken for a
  Foresight migration.
  """

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Migrations.Manifest
  alias Foresight.Migrations.Scratch

  @migration_source "foresight_schema_migrations"
  @lock_resource {__MODULE__, :install}
  @legacy_0_1_0_last_version 20_260_813_020_000

  defmodule Repo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :foresight,
      adapter: Ecto.Adapters.Postgres
  end

  @doc """
  Installs or upgrades Foresight control-plane tables in `repo`.

  The migration source is always the copy packaged with the running Foresight
  application (`priv/repo/migrations`). The operation is idempotent and returns
  only versions applied by this invocation:

      {:ok, %{migrated_versions: versions}}

  `:log` and `:log_migrator_sql` are forwarded to Ecto's migrator. Errors are
  returned as `{:error, reason}`. A manifest mismatch or a changed filename/content
  for an already-applied version fails closed.
  """
  @spec install(module(), keyword()) ::
          {:ok, %{migrated_versions: [integer()]}} | {:error, term()}
  def install(repo, opts \\ [])

  def install(repo, opts) when is_atom(repo) and is_list(opts) do
    :global.trans({@lock_resource, self()}, fn -> do_install(repo, opts) end)
  end

  def install(_repo, _opts), do: {:error, :invalid_repo}

  @doc "Returns the absolute packaged migration directory used by `install/2`."
  @spec migrations_path() :: String.t()
  def migrations_path do
    Application.app_dir(:foresight, "priv/repo/migrations")
  end

  defp do_install(repo, opts) do
    path = migrations_path()

    with :ok <- Manifest.validate(path),
         {:ok, migrations} <- migration_metadata(path, Manifest.files(:control)),
         {:ok, migration_repo, previous_env} <- start_migration_repo(repo) do
      try do
        run_with_repo(migration_repo, migrations, opts)
      after
        restore_migration_repo(previous_env, migration_repo)
      end
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_with_repo(migration_repo, migrations, opts) do
    previous_dynamic_repo = Repo.put_dynamic_repo(migration_repo)

    try do
      with :ok <- ensure_ledger_identity_columns(),
           :ok <- adopt_legacy_control_migrations(migrations),
           :ok <- reconcile_applied_identities(migrations),
           {:ok, temp_path} <- Scratch.materialize(migrations) do
        try do
          migrated_versions =
            with_module_conflict_ignored(fn ->
              Migrator.run(
                Repo,
                temp_path,
                :up,
                all: true,
                log: Keyword.get(opts, :log, false),
                log_migrator_sql: Keyword.get(opts, :log_migrator_sql, false)
              )
            end)

          with :ok <- reconcile_applied_identities(migrations) do
            {:ok, %{migrated_versions: migrated_versions}}
          end
        after
          File.rm_rf!(temp_path)
        end
      end
    after
      Repo.put_dynamic_repo(previous_dynamic_repo)
    end
  end

  defp start_migration_repo(repo) do
    previous_env = Application.get_env(:foresight, Repo)

    config =
      repo.config()
      |> Keyword.drop([:name, :otp_app, :telemetry_prefix])
      |> Keyword.put(:migration_source, @migration_source)
      |> Keyword.put(:pool_size, max(Keyword.get(repo.config(), :pool_size, 10), 2))

    Application.put_env(:foresight, Repo, config)

    case Repo.start_link(name: nil) do
      {:ok, pid} ->
        {:ok, pid, previous_env}

      {:error, reason} ->
        restore_env(previous_env)
        {:error, {:migration_repo_start_failed, reason}}
    end
  end

  defp restore_migration_repo(previous_env, migration_repo) do
    Supervisor.stop(migration_repo)
    restore_env(previous_env)
  end

  defp restore_env(nil), do: Application.delete_env(:foresight, Repo)
  defp restore_env(config), do: Application.put_env(:foresight, Repo, config)

  defp ensure_ledger_identity_columns do
    statements = [
      """
      CREATE TABLE IF NOT EXISTS #{@migration_source} (
        version bigint PRIMARY KEY,
        inserted_at timestamp(0) without time zone
      )
      """,
      "ALTER TABLE #{@migration_source} ADD COLUMN IF NOT EXISTS migration_name text",
      "ALTER TABLE #{@migration_source} ADD COLUMN IF NOT EXISTS migration_digest text"
    ]

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case SQL.query(Repo.get_dynamic_repo(), statement, []) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reconcile_applied_identities(migrations) do
    case SQL.query(
           Repo.get_dynamic_repo(),
           """
           SELECT version, migration_name, migration_digest
           FROM #{@migration_source}
           """,
           []
         ) do
      {:ok, %{rows: rows}} ->
        expected = Map.new(migrations, &{&1.version, &1})

        Enum.reduce_while(rows, :ok, fn [version, name, digest], :ok ->
          case Map.fetch(expected, version) do
            {:ok, %{filename: ^name, digest: ^digest}} ->
              {:cont, :ok}

            {:ok, migration} when is_nil(name) and is_nil(digest) ->
              case verify_control_schema(migration) do
                :ok ->
                  case stamp_identity(migration) do
                    :ok -> {:cont, :ok}
                    {:error, _reason} = error -> {:halt, error}
                  end

                {:error, _reason} = error ->
                  {:halt, error}
              end

            {:ok, %{filename: expected_name, digest: expected_digest}} ->
              {:halt,
               {:error,
                {:migration_identity_collision,
                 %{
                   version: version,
                   expected: {expected_name, expected_digest},
                   recorded: {name, digest}
                 }}}}

            :error ->
              {:halt, {:error, {:unexpected_foresight_migration_version, version}}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_control_schema(%{version: version}) do
    {table, columns} =
      case version do
        20_260_624_092_500 ->
          {"oban_jobs", ~w(id state queue worker args attempt max_attempts inserted_at)}

        20_260_625_162_000 ->
          {"tenant_lifecycles",
           ~w(tenant_id prefix status last_error metadata last_provisioned_at last_deleted_at inserted_at updated_at)}

        20_260_625_170_000 ->
          {"tenant_keys", ~w(id slug api_key_hash role_name inserted_at updated_at)}

        20_260_710_120_000 ->
          {"tenant_keys", ~w(prefix)}
      end

    case SQL.query(
           Repo.get_dynamic_repo(),
           """
           SELECT count(*) = $3
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = $1
             AND column_name = ANY($2::text[])
           """,
           [table, columns, length(columns)]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, {:unverified_migration_identity, version}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stamp_identity(migration) do
    case SQL.query(
           Repo.get_dynamic_repo(),
           """
           UPDATE #{@migration_source}
           SET migration_name = $2, migration_digest = $3
           WHERE version = $1
             AND migration_name IS NULL
             AND migration_digest IS NULL
           """,
           [migration.version, migration.filename, migration.digest]
         ) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        {:error, {:migration_identity_collision, migration.version}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Foresight 0.1.0 told standalone deployments to run the complete packaged
  # migration directory with the default `schema_migrations` ledger. Adopt that
  # exact, structurally verified state once so 0.1.1 does not replay the control
  # migrations against tables that already exist. A host version collision alone
  # is never enough: all control versions and their resulting schema must match.
  defp adopt_legacy_control_migrations(migrations) do
    with {:ok, true} <- ledger_empty?(),
         {:ok, true} <- legacy_control_versions_applied?(migrations),
         {:ok, true} <- legacy_control_schema_present?() do
      migrations
      |> Enum.filter(&(&1.version <= @legacy_0_1_0_last_version))
      |> insert_adopted_identities()
    else
      {:ok, false} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ledger_empty? do
    case SQL.query(
           Repo.get_dynamic_repo(),
           "SELECT count(*) FROM #{@migration_source}",
           []
         ) do
      {:ok, %{rows: [[0]]}} -> {:ok, true}
      {:ok, %{rows: [[_count]]}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_control_versions_applied?(_migrations) do
    legacy_versions =
      Manifest.entries()
      |> Map.keys()
      |> Enum.map(fn filename ->
        {version, "_" <> _name} = Integer.parse(filename)
        version
      end)
      |> Enum.filter(&(&1 <= @legacy_0_1_0_last_version))

    case SQL.query(
           Repo.get_dynamic_repo(),
           "SELECT to_regclass('public.schema_migrations') IS NOT NULL",
           []
         ) do
      {:ok, %{rows: [[false]]}} ->
        {:ok, false}

      {:ok, %{rows: [[true]]}} ->
        case SQL.query(
               Repo.get_dynamic_repo(),
               """
               SELECT count(*) = $2
               FROM public.schema_migrations
               WHERE version = ANY($1)
               """,
               [legacy_versions, length(legacy_versions)]
             ) do
          {:ok, %{rows: [[applied?]]}} -> {:ok, applied?}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp legacy_control_schema_present? do
    case SQL.query(
           Repo.get_dynamic_repo(),
           """
           SELECT
             to_regclass('public.oban_jobs') IS NOT NULL
             AND to_regclass('public.tenant_lifecycles') IS NOT NULL
             AND to_regclass('public.tenant_keys') IS NOT NULL
             AND to_regclass('public.banks') IS NOT NULL
             AND to_regclass('public.memory_units') IS NOT NULL
             AND to_regclass('public.labeled_pairs') IS NOT NULL
             AND EXISTS (
               SELECT 1
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = 'tenant_keys'
                 AND column_name = 'prefix'
             )
           """,
           []
         ) do
      {:ok, %{rows: [[present?]]}} -> {:ok, present?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_adopted_identities(migrations) do
    case Repo.transaction(fn ->
           Enum.each(migrations, fn migration ->
             SQL.query!(
               Repo.get_dynamic_repo(),
               """
               INSERT INTO #{@migration_source}
                 (version, inserted_at, migration_name, migration_digest)
               VALUES ($1, now(), $2, $3)
               """,
               [migration.version, migration.filename, migration.digest]
             )
           end)
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp migration_metadata(path, filenames) do
    migrations =
      Enum.map(filenames, fn filename ->
        file_path = Path.join(path, filename)
        {version, "_" <> _name} = Integer.parse(filename)
        digest = :crypto.hash(:sha256, File.read!(file_path)) |> Base.encode16(case: :lower)
        %{version: version, filename: filename, digest: digest, path: file_path}
      end)

    versions = Enum.map(migrations, & &1.version)

    if length(versions) == length(Enum.uniq(versions)) do
      {:ok, migrations}
    else
      {:error, {:migration_version_collision, versions -- Enum.uniq(versions)}}
    end
  rescue
    error -> {:error, error}
  end

  defp with_module_conflict_ignored(fun) do
    previous = Map.get(Code.compiler_options(), :ignore_module_conflict, false)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(ignore_module_conflict: previous)
    end
  end
end
