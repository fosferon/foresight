defmodule Foresight.Tenancy.SchemaProvisionerTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Schemas.TenantLifecycle
  alias Foresight.Tenancy.SchemaCloner
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.TestSupport.PostgresHarness

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 10
      )
    )

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    SchemaCloner.invalidate_snapshot()
    :ok
  end

  test "ensure_template provisions and snapshots foresight_template" do
    assert {:ok, %{prefix: "foresight_template", migrated_versions: migrated_versions}} =
             SchemaProvisioner.ensure_template(repo: Foresight.Repo)

    assert SchemaProvisioner.schema_exists?("foresight_template", repo: Foresight.Repo)
    assert SchemaCloner.snapshot_loaded?()
    assert is_list(migrated_versions)

    assert {:ok, %{rows: [[count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM foresight_template.schema_migrations",
               []
             )

    assert count > 0
  end

  test "provision clones from foresight_template when the template is ready" do
    prefix = "tenant_clone_path"
    test_pid = self()
    handler_id = "foresight-clone-path-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:foresight, :tenancy, :schema, :clone, :complete],
      fn _event, _measurements, %{prefix: cloned_prefix}, _config ->
        send(test_pid, {:clone_complete, cloned_prefix})
      end,
      nil
    )

    try do
      assert {:ok, _} = SchemaProvisioner.ensure_template(repo: Foresight.Repo)

      assert {:ok, %{prefix: ^prefix, migrated_versions: migrated_versions}} =
               SchemaProvisioner.provision(prefix, repo: Foresight.Repo)

      assert migrated_versions != []
      assert_receive {:clone_complete, ^prefix}, 5_000

      assert {:ok, %{rows: [[count]]}} =
               SQL.query(
                 Foresight.Repo,
                 "SELECT count(*) FROM tenant_clone_path.schema_migrations",
                 []
               )

      assert count == length(migrated_versions)

      assert {:ok, tracked} = SchemaProvisioner.tracked_tenants(repo: Foresight.Repo)

      assert %TenantLifecycle{tenant_id: ^prefix, prefix: ^prefix, status: "provisioned"} =
               Enum.find(tracked, &(&1.tenant_id == prefix))
    after
      :telemetry.detach(handler_id)
    end
  end

  test "drop removes a provisioned tenant schema and records deletion" do
    prefix = "tenant_to_drop"

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo)
    assert SchemaProvisioner.schema_exists?(prefix, repo: Foresight.Repo)
    assert :ok = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
    refute SchemaProvisioner.schema_exists?(prefix, repo: Foresight.Repo)

    assert {:ok, tracked} = SchemaProvisioner.tracked_tenants(repo: Foresight.Repo)

    assert %TenantLifecycle{tenant_id: ^prefix, prefix: ^prefix, status: "deleted"} =
             Enum.find(tracked, &(&1.tenant_id == prefix))
  end
end
