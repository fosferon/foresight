defmodule Foresight.Tenancy.PostureMonitorTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Tenancy.PostureMonitor
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.Tenancy.TenantKeys
  alias Foresight.TestSupport.PostgresHarness

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 4,
        after_connect: {Postgrex, :query!, ["RESET ROLE", []]}
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

  test "reports healthy for provisioned mode_c tenants with working roles" do
    tenant = provision_tenant!("tenant-monitor-ok", "tenant_monitor_ok", "tenant_monitor_ok_role")

    on_exit(fn -> drop_tenant!(tenant) end)

    config = %{
      repo: %{enabled: true, module: Foresight.Repo},
      tenancy: %{
        enabled: true,
        rls_enabled: true,
        posture_monitor: %{enabled: true, interval_ms: 60_000}
      }
    }

    {:ok, pid} =
      start_supervised(
        {PostureMonitor, name: unique_name(), config: config, repo: Foresight.Repo}
      )

    status = PostureMonitor.run_now(pid)

    assert status.status == :healthy
    assert status.probe_count == 1
    assert status.failures == []
  end

  test "reports unhealthy when a tracked tenant role is missing" do
    tenant =
      provision_tenant!("tenant-monitor-bad", "tenant_monitor_bad", "tenant_monitor_bad_role")

    revoke_and_drop_role!(tenant.prefix, tenant.role_name)

    on_exit(fn ->
      assert :ok = TenantKeys.delete(tenant.slug, "secret", repo: Foresight.Repo)

      _ =
        SchemaProvisioner.drop(tenant.prefix,
          repo: Foresight.Repo,
          rls_enabled: true,
          tenant_id: tenant.slug
        )
    end)

    config = %{
      repo: %{enabled: true, module: Foresight.Repo},
      tenancy: %{
        enabled: true,
        rls_enabled: true,
        posture_monitor: %{enabled: true, interval_ms: 60_000}
      }
    }

    {:ok, pid} =
      start_supervised(
        {PostureMonitor, name: unique_name(), config: config, repo: Foresight.Repo}
      )

    status = PostureMonitor.run_now(pid)

    assert status.status == :unhealthy
    assert status.probe_count == 1

    assert Enum.any?(status.failures, fn failure ->
             failure.tenant_id == tenant.slug and
               String.contains?(failure.message, "does not exist")
           end)
  end

  test "recovers after a crash and re-probes tracked tenants" do
    tenant =
      provision_tenant!(
        "tenant-monitor-restart",
        "tenant_monitor_restart",
        "tenant_monitor_restart_role"
      )

    on_exit(fn -> drop_tenant!(tenant) end)

    name = unique_name()

    config = %{
      repo: %{enabled: true, module: Foresight.Repo},
      tenancy: %{
        enabled: true,
        rls_enabled: true,
        posture_monitor: %{enabled: true, interval_ms: 60_000}
      }
    }

    {:ok, _pid} =
      start_supervised({PostureMonitor, name: name, config: config, repo: Foresight.Repo})

    assert %{status: :healthy, probe_count: 1, failures: []} = PostureMonitor.run_now(name)

    original_pid = Process.whereis(name)
    assert is_pid(original_pid)
    Process.exit(original_pid, :kill)

    assert eventually(fn ->
             restarted_pid = Process.whereis(name)
             is_pid(restarted_pid) and restarted_pid != original_pid
           end)

    assert %{status: :healthy, probe_count: 1, failures: []} = PostureMonitor.run_now(name)
    # Asserts the connection returned to its own login role, not the literal "postgres" —
    # the monitor must work under a non-superuser app login.
    assert {:ok, %{rows: [[role, role]]}} =
             SQL.query(Foresight.Repo, "SELECT current_role, session_user", [])
  end

  test "restarts cleanly and surfaces drift introduced while it was down" do
    tenant =
      provision_tenant!(
        "tenant-monitor-restart-drift",
        "tenant_monitor_restart_drift",
        "tenant_monitor_restart_drift_role"
      )

    on_exit(fn ->
      assert :ok = TenantKeys.delete(tenant.slug, "secret", repo: Foresight.Repo)

      _ =
        SchemaProvisioner.drop(tenant.prefix,
          repo: Foresight.Repo,
          rls_enabled: true,
          tenant_id: tenant.slug
        )
    end)

    name = unique_name()

    config = %{
      repo: %{enabled: true, module: Foresight.Repo},
      tenancy: %{
        enabled: true,
        rls_enabled: true,
        posture_monitor: %{enabled: true, interval_ms: 60_000}
      }
    }

    {:ok, _pid} =
      start_supervised({PostureMonitor, name: name, config: config, repo: Foresight.Repo})

    assert %{status: :healthy, probe_count: 1, failures: []} = PostureMonitor.run_now(name)

    original_pid = Process.whereis(name)
    assert is_pid(original_pid)
    Process.exit(original_pid, :kill)

    revoke_and_drop_role!(tenant.prefix, tenant.role_name)

    assert eventually(fn ->
             restarted_pid = Process.whereis(name)
             is_pid(restarted_pid) and restarted_pid != original_pid
           end)

    status = PostureMonitor.run_now(name)

    assert status.status == :unhealthy
    assert status.probe_count == 1

    assert Enum.any?(status.failures, fn failure ->
             failure.tenant_id == tenant.slug and
               String.contains?(failure.message, "does not exist")
           end)
  end

  test "re-probes successfully after the repo process is restarted" do
    tenant =
      provision_tenant!(
        "tenant-monitor-repo-restart",
        "tenant_monitor_repo_restart",
        "tenant_monitor_repo_restart_role"
      )

    on_exit(fn -> drop_tenant!(tenant) end)

    name = unique_name()

    config = %{
      repo: %{enabled: true, module: Foresight.Repo},
      tenancy: %{
        enabled: true,
        rls_enabled: true,
        posture_monitor: %{enabled: true, interval_ms: 60_000}
      }
    }

    {:ok, _pid} =
      start_supervised({PostureMonitor, name: name, config: config, repo: Foresight.Repo})

    assert %{status: :healthy, probe_count: 1, failures: []} = PostureMonitor.run_now(name)

    repo_pid = Process.whereis(Foresight.Repo)
    assert is_pid(repo_pid)
    Process.exit(repo_pid, :kill)

    assert eventually(fn ->
             restarted_repo_pid = Process.whereis(Foresight.Repo)
             is_pid(restarted_repo_pid) and restarted_repo_pid != repo_pid
           end)

    assert %{status: :healthy, probe_count: 1, failures: []} = PostureMonitor.run_now(name)
    # Asserts the connection returned to its own login role, not the literal "postgres" —
    # the monitor must work under a non-superuser app login.
    assert {:ok, %{rows: [[role, role]]}} =
             SQL.query(Foresight.Repo, "SELECT current_role, session_user", [])
  end

  defp provision_tenant!(slug, prefix, role_name) do
    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo, rls_enabled: true, tenant_id: slug)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])

    assert {:ok, _} =
             SchemaProvisioner.provision(prefix,
               repo: Foresight.Repo,
               rls_enabled: true,
               tenant_id: slug
             )

    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "#{role_name}" NOINHERIT|, [])
    SQL.query!(Foresight.Repo, ~s|GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role_name}"|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      []
    )

    assert {:ok, _} = TenantKeys.put(slug, "secret", role_name, repo: Foresight.Repo)
    %{slug: slug, prefix: prefix, role_name: role_name}
  end

  defp drop_tenant!(tenant) do
    assert :ok = TenantKeys.delete(tenant.slug, "secret", repo: Foresight.Repo)

    _ =
      SchemaProvisioner.drop(tenant.prefix,
        repo: Foresight.Repo,
        rls_enabled: true,
        tenant_id: tenant.slug
      )

    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{tenant.role_name}"|, [])
  end

  defp revoke_and_drop_role!(prefix, role_name) do
    SQL.query!(Foresight.Repo, ~s|REVOKE USAGE ON SCHEMA "#{prefix}" FROM "#{role_name}"|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA "#{prefix}" FROM "#{role_name}"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA "#{prefix}" FROM "#{role_name}"|,
      []
    )

    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])
  end

  defp unique_name do
    Module.concat(__MODULE__, "Monitor#{System.unique_integer([:positive])}")
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end
end
