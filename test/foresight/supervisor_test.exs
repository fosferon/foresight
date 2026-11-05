defmodule Foresight.SupervisorTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Schemas.TenantLifecycle
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.TestSupport.PostgresHarness

  defmodule FakeWorker do
    use Agent

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      Agent.start_link(fn -> opts end, name: name)
    end
  end

  defmodule FakePostureMonitor do
    use Agent

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      Agent.start_link(fn -> opts end, name: name)
    end

    def status(server) do
      if Process.whereis(server) do
        %{status: :healthy, probe_count: 0, last_run_at: nil, failures: []}
      else
        %{status: :disabled}
      end
    end
  end

  defmodule FakeReconciler do
    use Agent

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      Agent.start_link(fn -> opts end, name: name)
    end
  end

  defmodule FakeMcpRegistry do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> :up end, name: __MODULE__)
  end

  defmodule FakeMcpServer do
    use Agent

    # The real Hermes server registers itself against the registry on start, so starting
    # before the registry is up cannot work. Fail loudly here so the ordering is asserted
    # by actually booting, not by inspecting a list.
    def start_link(opts) do
      unless Process.whereis(FakeMcpRegistry) do
        raise "mcp server started before its registry"
      end

      Agent.start_link(fn -> opts end, name: Keyword.fetch!(opts, :name))
    end
  end

  # mcp: [enabled: true] could not boot at all — the server was listed ahead
  # of the registry it depends on. It survived because every other supervisor test runs
  # with mcp disabled, and the MCP suites start the server directly.
  test "boots the MCP server after its registry when mcp is enabled" do
    server_name = Module.concat(__MODULE__, McpServer)

    {:ok, supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, McpSupervisor),
        runtime_names: %{mcp_server: server_name, http: Module.concat(__MODULE__, McpEndpoint)},
        repo: [enabled: false],
        oban: [enabled: false],
        # Streamable-HTTP MCP requires the HTTP face; preflight enforces it. Preflight also
        # refuses an anonymous HTTP deploy, hence the service key.
        http: [enabled: true, port: free_port()],
        auth: [api_key: "supervisor-test-key"],
        ml: [enabled: false],
        file_ingestion: [enabled: false],
        mcp: [enabled: true, registry: FakeMcpRegistry, server: FakeMcpServer]
      )

    assert Process.whereis(server_name)
    assert Process.whereis(FakeMcpRegistry)
    Supervisor.stop(supervisor)
  end

  test "starts file ingestion worker only when the feature is enabled" do
    python_executable = write_probe_script!("exit 0\n")

    on_exit(fn -> File.rm(python_executable) end)

    disabled_name = Module.concat(__MODULE__, DisabledWorker)

    {:ok, disabled_supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, DisabledSupervisor),
        runtime_names: %{file_ingestion: disabled_name},
        repo: [enabled: false],
        oban: [enabled: false],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: false, worker: FakeWorker]
      )

    refute Process.whereis(disabled_name)
    Supervisor.stop(disabled_supervisor)

    enabled_name = Module.concat(__MODULE__, EnabledWorker)

    {:ok, _enabled_supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, EnabledSupervisor),
        runtime_names: %{file_ingestion: enabled_name},
        repo: [enabled: false],
        oban: [enabled: false],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: true, worker: FakeWorker, python_executable: python_executable]
      )

    assert Process.whereis(enabled_name)
  end

  test "starts the python ML worker when the sentence-transformers backend is active" do
    worker_name = Module.concat(__MODULE__, PythonMLWorker)

    {:ok, _supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, PythonMLSupervisor),
        runtime_names: %{python_ml_worker: worker_name},
        repo: [enabled: false],
        oban: [enabled: false],
        http: [enabled: false],
        file_ingestion: [enabled: false],
        engine: [
          embedder: Foresight.Embedders.SentenceTransformers,
          reranker: Foresight.Rerankers.SentenceTransformers
        ],
        ml: [
          enabled: false,
          python_worker_module: FakeWorker,
          python_worker_name: worker_name,
          preload_models: true
        ]
      )

    assert Process.whereis(worker_name)
  end

  test "starts a dedicated public repo only when configured" do
    harness = PostgresHarness.start!()
    public_repo_name = Module.concat(__MODULE__, PublicRepo)

    on_exit(fn ->
      PostgresHarness.stop!(harness)
    end)

    {:ok, supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, PublicRepoSupervisor),
        runtime_names: %{public_repo: public_repo_name},
        repo: [
          enabled: false,
          public: [
            enabled: true,
            module: Foresight.PublicRepo,
            start_opts: [url: harness.url, pool_size: 2]
          ]
        ],
        oban: [enabled: false],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: false]
      )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert eventually(fn ->
             Enum.any?(Supervisor.which_children(supervisor), fn
               {{:public_repo, ^public_repo_name}, pid, _kind, _modules} when is_pid(pid) -> true
               _child -> false
             end)
           end)
  end

  test "starts the configured posture monitor under the configured runtime name" do
    posture_name = Module.concat(__MODULE__, CustomPostureMonitor)
    tenant_key_cache = Module.concat(__MODULE__, TenantKeyCache)

    {:ok, _supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, PostureMonitorSupervisor),
        runtime_names: %{tenant_key_cache: tenant_key_cache},
        repo: [enabled: false],
        oban: [enabled: false],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: false],
        tenancy: [
          enabled: true,
          reconciler: FakeReconciler,
          posture_monitor: [
            enabled: true,
            module: FakePostureMonitor,
            name: posture_name
          ]
        ]
      )

    assert Process.whereis(posture_name)
    assert Process.whereis(tenant_key_cache)
    assert FakePostureMonitor.status(posture_name).status == :healthy
  end

  test "restarts the configured posture monitor after a crash" do
    posture_name = Module.concat(__MODULE__, RestartingPostureMonitor)
    tenant_key_cache = Module.concat(__MODULE__, RestartingTenantKeyCache)

    {:ok, _supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, RestartingPostureMonitorSupervisor),
        runtime_names: %{tenant_key_cache: tenant_key_cache},
        repo: [enabled: false],
        oban: [enabled: false],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: false],
        tenancy: [
          enabled: true,
          reconciler: FakeReconciler,
          posture_monitor: [
            enabled: true,
            module: FakePostureMonitor,
            name: posture_name
          ]
        ]
      )

    original_pid = Process.whereis(posture_name)
    assert is_pid(original_pid)

    Process.exit(original_pid, :kill)

    assert eventually(fn ->
             restarted_pid = Process.whereis(posture_name)
             is_pid(restarted_pid) and restarted_pid != original_pid
           end)

    assert FakePostureMonitor.status(posture_name).status == :healthy
  end

  test "boots Oban with every declared queue when the async subsystem is enabled" do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 5)
    )

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    # Previously this crashed the supervisor: Config.resolve/1 coerced the queues
    # keyword list into a map that Oban.Config rejects, so the async subsystem could
    # not boot at all. This test asserts it now starts with all seven queues.
    {:ok, supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, ObanSupervisor),
        repo: [enabled: false, module: Foresight.Repo],
        oban: [enabled: true],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: false]
      )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    # The boot itself is the regression proof — it crashed before the fix.
    assert Process.alive?(supervisor)

    queue_names =
      Foresight.Oban |> Oban.config() |> Map.get(:queues) |> Keyword.keys() |> Enum.sort()

    assert queue_names == [
             :foresight_consolidate,
             :foresight_embedding_backfill,
             :foresight_migrate_bank,
             :foresight_probe_bank,
             :foresight_refresh_mental_model,
             :foresight_retain,
             :foresight_webhook_delivery
           ]
  end

  test "starts tenancy runtime and reconciles tracked provisioning tenants when the feature is enabled" do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 10,
        telemetry_prefix: [:foresight, :reconciliation_test]
      )
    )

    runtime_registry = Module.concat(__MODULE__, TenancyRegistry)
    runtime_supervisor = Module.concat(__MODULE__, TenancyRuntimeSupervisor)
    reconciler = Module.concat(__MODULE__, TenancyReconciler)
    prefix = "tenant_boot_reconciled"

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    start_supervised!(Foresight.Repo)

    migrations_path =
      Path.expand("../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    Foresight.Repo.insert!(
      TenantLifecycle.changeset(%TenantLifecycle{}, %{
        tenant_id: prefix,
        prefix: prefix,
        status: "provisioning"
      })
    )

    # Reconciliation first builds and snapshots the tenant template. Hold one
    # query after it executes to prove the test awaits that startup work rather
    # than imposing a one-second deadline on real migrations.
    test_pid = self()
    handler_id = "supervisor-reconciliation-slow-template"

    :ok =
      :telemetry.attach(
        handler_id,
        [:foresight, :reconciliation_test, :query],
        fn _event, _measurements, metadata, _config ->
          if String.starts_with?(
               metadata.query || "",
               ~s(CREATE SCHEMA IF NOT EXISTS "foresight_template")
             ) do
            send(test_pid, :template_creation_delayed)
            Process.sleep(1_500)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, supervisor} =
      Foresight.Supervisor.start_link(
        name: Module.concat(__MODULE__, TenancySupervisor),
        runtime_names: %{
          tenancy_registry: runtime_registry,
          tenancy_runtime_supervisor: runtime_supervisor,
          tenancy_reconciler: reconciler
        },
        repo: [enabled: false, module: Foresight.Repo],
        oban: [enabled: false],
        http: [enabled: false],
        ml: [enabled: false],
        file_ingestion: [enabled: false],
        tenancy: [enabled: true, known_prefixes: []]
      )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        try do
          Supervisor.stop(supervisor)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    # init queues :reconcile before start_link returns. A system-state request
    # completes only after that first reconciliation, whether it succeeded or
    # failed; the assertions below still verify its actual persisted effects.
    assert is_list(:sys.get_state(reconciler, 30_000))
    assert_received :template_creation_delayed
    assert SchemaProvisioner.schema_exists?(prefix, repo: Foresight.Repo)

    assert {:ok, lifecycles} = SchemaProvisioner.tracked_tenants(repo: Foresight.Repo)

    assert Enum.any?(lifecycles, &(&1.tenant_id == prefix and &1.status == "provisioned"))

    assert match?(
             [{_pid, _value}],
             Registry.lookup(runtime_registry, {:tenant_supervisor, prefix})
           )
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

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp write_probe_script!(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "foresight-supervisor-docling-probe-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, "#!/bin/sh\n#{body}")
    File.chmod!(path, 0o755)
    path
  end
end
