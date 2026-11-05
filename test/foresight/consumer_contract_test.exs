defmodule Foresight.ConsumerContractTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Foresight.AsyncOptions
  alias Foresight.AsyncQueues.Oban, as: AsyncQueue
  alias Foresight.Context
  alias Foresight.Migrations
  alias Foresight.Migrations.Manifest
  alias Foresight.Schemas.Delivery
  alias Foresight.Schemas.TenantKey
  alias Foresight.Tenancy
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.TestSupport.PostgresHarness

  defmodule ConsumerRepo do
    use Ecto.Repo,
      otp_app: :foresight_consumer_contract,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule CollisionRepo do
    use Ecto.Repo,
      otp_app: :foresight_consumer_contract,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule UpgradeRepo do
    use Ecto.Repo,
      otp_app: :foresight_consumer_contract,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule IncompleteRepo do
    use Ecto.Repo,
      otp_app: :foresight_consumer_contract,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule StorageSpy do
    def retain(_ctx, _payload, opts) do
      send(Process.get(:consumer_contract_test), {:worker_opts, opts})
      {:ok, %{"items_count" => 0}}
    end
  end

  defmodule FailingInsertEngine do
    @behaviour Oban.Engine

    @impl true
    defdelegate init(conf, opts), to: Oban.Engines.Basic
    @impl true
    defdelegate put_meta(conf, meta, key, value), to: Oban.Engines.Basic
    @impl true
    defdelegate check_meta(conf, meta, running), to: Oban.Engines.Basic
    @impl true
    defdelegate refresh(conf, meta), to: Oban.Engines.Basic
    @impl true
    defdelegate shutdown(conf, meta), to: Oban.Engines.Basic
    @impl true
    defdelegate fetch_jobs(conf, meta, running), to: Oban.Engines.Basic
    @impl true
    defdelegate complete_job(conf, job), to: Oban.Engines.Basic
    @impl true
    defdelegate discard_job(conf, job), to: Oban.Engines.Basic
    @impl true
    defdelegate error_job(conf, job, seconds), to: Oban.Engines.Basic
    @impl true
    defdelegate snooze_job(conf, job, seconds), to: Oban.Engines.Basic
    @impl true
    defdelegate cancel_job(conf, job), to: Oban.Engines.Basic
    @impl true
    defdelegate cancel_all_jobs(conf, query), to: Oban.Engines.Basic
    @impl true
    defdelegate retry_job(conf, job), to: Oban.Engines.Basic
    @impl true
    defdelegate retry_all_jobs(conf, query), to: Oban.Engines.Basic
    @impl true
    defdelegate insert_all_jobs(conf, jobs, opts), to: Oban.Engines.Basic

    @impl true
    def insert_job(_conf, _changeset, _opts), do: {:error, :simulated_enqueue_failure}
  end

  setup_all do
    consumer = PostgresHarness.start!()
    collision = PostgresHarness.start!()
    upgrade = PostgresHarness.start!()
    incomplete = PostgresHarness.start!()

    Application.put_env(:foresight_consumer_contract, ConsumerRepo,
      url: consumer.url,
      pool_size: 10,
      types: Foresight.PostgrexTypes,
      telemetry_prefix: [:consumer_contract_repo]
    )

    Application.put_env(:foresight_consumer_contract, CollisionRepo,
      url: collision.url,
      pool_size: 10
    )

    Application.put_env(:foresight_consumer_contract, UpgradeRepo,
      url: upgrade.url,
      pool_size: 10
    )

    Application.put_env(:foresight_consumer_contract, IncompleteRepo,
      url: incomplete.url,
      pool_size: 10
    )

    start_supervised!(ConsumerRepo)
    start_supervised!(CollisionRepo)
    start_supervised!(UpgradeRepo)
    start_supervised!(IncompleteRepo)

    assert {:ok, initial_install} = Migrations.install(ConsumerRepo)
    role_count_before_provision = role_count()

    assert {:ok, initial_provision} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "consumer_contract_tenant",
               rls_enabled: false
             )

    role_count_after_provision = role_count()

    on_exit(fn ->
      Application.delete_env(:foresight_consumer_contract, ConsumerRepo)
      Application.delete_env(:foresight_consumer_contract, CollisionRepo)
      Application.delete_env(:foresight_consumer_contract, UpgradeRepo)
      Application.delete_env(:foresight_consumer_contract, IncompleteRepo)
      PostgresHarness.stop!(consumer)
      PostgresHarness.stop!(collision)
      PostgresHarness.stop!(upgrade)
      PostgresHarness.stop!(incomplete)
    end)

    {:ok,
     initial_install: initial_install,
     initial_provision: initial_provision,
     role_counts: {role_count_before_provision, role_count_after_provision}}
  end

  test "packaged manifest is exhaustive and package path is available" do
    path = Migrations.migrations_path()

    assert path == Application.app_dir(:foresight, "priv/repo/migrations")
    assert File.dir?(path)
    assert :ok = Manifest.validate(path)

    assert Map.keys(Manifest.entries()) |> Enum.sort() ==
             path
             |> Path.join("*.exs")
             |> Path.wildcard()
             |> Enum.map(&Path.basename/1)
             |> Enum.sort()

    assert Manifest.files(:public_data) == [
             "20260813020000_reclassify_agent_graded_labeled_pairs.exs"
           ]

    refute "20260813020000_reclassify_agent_graded_labeled_pairs.exs" in Manifest.files(:tenant)
  end

  test "consumer Repo installs only control tables and is idempotent", %{
    initial_install: %{migrated_versions: versions}
  } do
    assert length(versions) == length(Manifest.files(:control))
    assert {:ok, %{migrated_versions: []}} = Migrations.install(ConsumerRepo)

    for table <- ["oban_jobs", "tenant_lifecycles", "tenant_keys"] do
      assert {:ok, %{rows: [[qualified_name]]}} =
               SQL.query(ConsumerRepo, "SELECT to_regclass($1)::text", ["public.#{table}"])

      assert qualified_name == table
    end

    assert {:ok, %{rows: [[nil]]}} =
             SQL.query(ConsumerRepo, "SELECT to_regclass('public.banks')::text", [])

    assert {:ok, %{rows: [[ledger_count]]}} =
             SQL.query(ConsumerRepo, "SELECT count(*) FROM foresight_schema_migrations", [])

    assert ledger_count == length(Manifest.files(:control))
  end

  test "consumer install ignores scratch directories left by another BEAM" do
    original_tmpdir = System.get_env("TMPDIR")

    shared_tmpdir =
      Path.join(
        System.tmp_dir!(),
        "foresight-migration-collision-test-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    File.mkdir!(shared_tmpdir)

    [first, second | _] = Manifest.files(:control)
    next_integer = System.unique_integer([:positive, :monotonic])

    # A fresh BEAM can reuse the same monotonic sequence. Occupy the names it
    # would try next with an old, partially linked migration directory.
    stale_paths =
      for integer <- (next_integer + 1)..(next_integer + 512) do
        path = Path.join(shared_tmpdir, "foresight-control-migrations-#{integer}")
        File.mkdir!(path)
        File.ln_s!(Path.join(Migrations.migrations_path(), second), Path.join(path, second))
        path
      end

    try do
      System.put_env("TMPDIR", shared_tmpdir)
      assert System.tmp_dir!() == shared_tmpdir
      assert {:ok, %{migrated_versions: []}} = Migrations.install(ConsumerRepo)

      # None of the pre-existing directories may be borrowed or modified.
      for path <- stale_paths do
        refute File.exists?(Path.join(path, first))

        assert File.read_link(Path.join(path, second)) ==
                 {:ok, Path.join(Migrations.migrations_path(), second)}
      end
    after
      if original_tmpdir,
        do: System.put_env("TMPDIR", original_tmpdir),
        else: System.delete_env("TMPDIR")

      File.rm_rf!(shared_tmpdir)
    end
  end

  test "host schema_migrations collision is not accepted as a Foresight migration" do
    [first_control | _rest] = Manifest.files(:control)
    {version, _suffix} = Integer.parse(first_control)

    SQL.query!(
      CollisionRepo,
      """
      CREATE TABLE schema_migrations (
        version bigint PRIMARY KEY,
        inserted_at timestamp(0) without time zone
      )
      """,
      []
    )

    SQL.query!(
      CollisionRepo,
      "INSERT INTO schema_migrations(version, inserted_at) VALUES ($1, now())",
      [version]
    )

    assert {:ok, %{migrated_versions: migrated_versions}} = Migrations.install(CollisionRepo)
    assert version in migrated_versions

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               CollisionRepo,
               "SELECT count(*) FROM foresight_schema_migrations WHERE version = $1",
               [version]
             )

    assert {:ok, %{rows: [[qualified_name]]}} =
             SQL.query(CollisionRepo, "SELECT to_regclass('public.oban_jobs')::text", [])

    assert qualified_name == "oban_jobs"

    SQL.query!(
      CollisionRepo,
      """
      UPDATE foresight_schema_migrations
      SET migration_digest = 'tampered'
      WHERE version = $1
      """,
      [version]
    )

    assert {:error, {:migration_identity_collision, %{version: ^version}}} =
             Migrations.install(CollisionRepo)
  end

  test "adopts a structurally verified 0.1.0 control-plane installation" do
    path = Migrations.migrations_path()

    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(UpgradeRepo, fn repo ->
        Ecto.Migrator.run(repo, path, :up, all: true)
      end)

    SQL.query!(
      UpgradeRepo,
      "DELETE FROM schema_migrations WHERE version > $1",
      [20_260_813_020_000]
    )

    SQL.query!(
      UpgradeRepo,
      """
      CREATE TABLE foresight_schema_migrations (
        version bigint PRIMARY KEY,
        inserted_at timestamp(0) without time zone,
        migration_name text,
        migration_digest text
      )
      """,
      []
    )

    [_first_control, rejected_control | _rest] = Manifest.files(:control)
    {rejected_version, _suffix} = Integer.parse(rejected_control)

    SQL.query!(
      UpgradeRepo,
      """
      CREATE OR REPLACE FUNCTION reject_partial_foresight_adoption()
      RETURNS trigger AS $$
      BEGIN
        IF NEW.version = #{rejected_version} THEN
          RAISE EXCEPTION 'simulated adoption interruption';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      []
    )

    SQL.query!(
      UpgradeRepo,
      """
      CREATE TRIGGER reject_partial_foresight_adoption
      BEFORE INSERT ON foresight_schema_migrations
      FOR EACH ROW EXECUTE FUNCTION reject_partial_foresight_adoption()
      """,
      []
    )

    assert {:error, %Postgrex.Error{}} = Migrations.install(UpgradeRepo)

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(UpgradeRepo, "SELECT count(*) FROM foresight_schema_migrations", [])

    SQL.query!(
      UpgradeRepo,
      "DROP TRIGGER reject_partial_foresight_adoption ON foresight_schema_migrations",
      []
    )

    SQL.query!(UpgradeRepo, "DROP FUNCTION reject_partial_foresight_adoption()", [])

    assert {:ok, %{migrated_versions: []}} = Migrations.install(UpgradeRepo)

    assert {:ok, %{rows: [[count]]}} =
             SQL.query(UpgradeRepo, "SELECT count(*) FROM foresight_schema_migrations", [])

    assert count == length(Manifest.files(:control))

    assert {:ok, %{rows: [[identity_count]]}} =
             SQL.query(
               UpgradeRepo,
               """
               SELECT count(*)
               FROM foresight_schema_migrations
               WHERE migration_name IS NOT NULL
                 AND migration_digest IS NOT NULL
               """,
               []
             )

    assert identity_count == count
  end

  test "repairs an interrupted install with an unstamped ledger row" do
    [first_control | _rest] = Manifest.files(:control)
    {version, _suffix} = Integer.parse(first_control)

    SQL.query!(
      ConsumerRepo,
      """
      UPDATE foresight_schema_migrations
      SET migration_name = NULL, migration_digest = NULL
      WHERE version = $1
      """,
      [version]
    )

    assert {:ok, %{migrated_versions: []}} = Migrations.install(ConsumerRepo)

    assert {:ok, %{rows: [[^first_control, digest]]}} =
             SQL.query(
               ConsumerRepo,
               """
               SELECT migration_name, migration_digest
               FROM foresight_schema_migrations
               WHERE version = $1
               """,
               [version]
             )

    assert is_binary(digest)
  end

  test "refuses to stamp an applied version without its control-plane structure" do
    [first_control | _rest] = Manifest.files(:control)
    {version, _suffix} = Integer.parse(first_control)

    SQL.query!(
      IncompleteRepo,
      """
      CREATE TABLE foresight_schema_migrations (
        version bigint PRIMARY KEY,
        inserted_at timestamp(0) without time zone,
        migration_name text,
        migration_digest text
      )
      """,
      []
    )

    SQL.query!(
      IncompleteRepo,
      "INSERT INTO foresight_schema_migrations(version, inserted_at) VALUES ($1, now())",
      [version]
    )

    assert {:error, {:unverified_migration_identity, ^version}} =
             Migrations.install(IncompleteRepo)

    assert {:ok, %{rows: [[nil, nil]]}} =
             SQL.query(
               IncompleteRepo,
               "SELECT migration_name, migration_digest FROM foresight_schema_migrations WHERE version = $1",
               [version]
             )
  end

  test "rejects unknown ledger versions instead of silently accepting downgrade" do
    version = 9_999_999_999_999

    SQL.query!(
      ConsumerRepo,
      """
      INSERT INTO foresight_schema_migrations
        (version, inserted_at, migration_name, migration_digest)
      VALUES ($1, now(), 'future.exs', 'future')
      """,
      [version]
    )

    assert {:error, {:unexpected_foresight_migration_version, ^version}} =
             Migrations.install(ConsumerRepo)

    SQL.query!(
      ConsumerRepo,
      "DELETE FROM foresight_schema_migrations WHERE version = $1",
      [version]
    )
  end

  test "role-neutral Mode C provisioning requires RLS choice and mints no authority records", %{
    initial_provision: %{migrated_versions: initially_migrated_versions},
    role_counts: {role_count_before_provision, role_count_after_provision}
  } do
    assert initially_migrated_versions != []
    refute 20_260_813_020_000 in initially_migrated_versions
    assert role_count_after_provision == role_count_before_provision

    assert {:error, {:missing_option, :rls_enabled}} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "consumer_contract_tenant"
             )

    assert {:error, {:invalid_option, :rls_enabled, :expected_boolean}} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "consumer_contract_tenant",
               rls_enabled: :yes
             )

    assert {:ok,
            %{
              tenant_id: "consumer-tenant",
              prefix: "consumer_contract_tenant",
              migrated_versions: migrated_versions
            }} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "consumer_contract_tenant",
               rls_enabled: false
             )

    assert migrated_versions == []

    assert {:ok, %{tenant_id: "consumer-tenant", migrated_versions: []}} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "consumer_contract_tenant",
               rls_enabled: false
             )

    assert ConsumerRepo.aggregate(TenantKey, :count) == 0

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               ConsumerRepo,
               """
               SELECT count(*)
               FROM pg_roles
               WHERE rolname IN ('consumer-tenant', 'consumer_contract_tenant')
               """,
               []
             )
  end

  test "Mode C provisioning rejects public and returns migration failures as errors" do
    assert {:error, :reserved_tenant_prefix} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "public",
               rls_enabled: false
             )

    assert {:error, %RuntimeError{message: message}} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               "consumer_contract_broken",
               rls_enabled: false,
               migrations_path: "/does/not/exist"
             )

    assert message =~ "invalid Foresight migration manifest"
  end

  test "per-call false overrides app RLS true in ordinary and parallel recall scopes" do
    prefix = "consumer_contract_tenant"
    role_name = "consumer_contract_reader"
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_tenancy = Application.get_env(:foresight, :tenancy)

    create_tenant_role!(prefix, role_name)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: ConsumerRepo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

    Application.put_env(:foresight, :tenancy, rls_enabled: true)

    handler_id = "consumer-contract-query-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:consumer_contract_repo, :query],
      fn _event, _measurements, metadata, _config ->
        if String.contains?(metadata.query || "", "set_config") do
          send(test_pid, :set_config_query)
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
      restore_env(:tenancy, original_tenancy)
      drop_tenant_role!(role_name)
    end)

    ctx = %Context{
      tenant_id: "consumer-tenant",
      mode: :mode_c,
      bank: "consumer-bank",
      role_name: role_name,
      prefix: prefix
    }

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "consumer-bank", %{"name" => "Consumer"}, rls_enabled: false)

    assert {:ok, %{"results" => []}} =
             Foresight.recall(ctx, %{"query" => "nothing"}, rls_enabled: false)

    refute_receive :set_config_query, 100

    assert {:ok, _} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-tenant",
               prefix,
               rls_enabled: true
             )

    assert {:ok, %{"results" => []}} =
             Foresight.recall(ctx, %{"query" => "nothing"}, rls_enabled: true)

    assert_receive :set_config_query, 1_000
  end

  test "nested Mode B scopes retain one RLS scope until the outer call exits" do
    original_tenancy = Application.get_env(:foresight, :tenancy)
    Application.put_env(:foresight, :tenancy, rls_enabled: true)

    handler_id = "consumer-contract-mode-b-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:consumer_contract_repo, :query],
      fn _event, _measurements, metadata, _config ->
        cond do
          String.contains?(metadata.query || "", "set_config") -> send(test_pid, :set_scope)
          String.starts_with?(metadata.query || "", "RESET") -> send(test_pid, :reset_scope)
          true -> :ok
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(:tenancy, original_tenancy)
    end)

    ctx = %Context{
      tenant_id: "consumer-tenant",
      mode: :mode_b,
      bank: "consumer-bank",
      prefix: "consumer_contract_tenant"
    }

    assert :ok =
             Tenancy.with_tenant_role(
               ctx,
               fn ->
                 assert :ok =
                          Tenancy.with_tenant_role(ctx, fn -> :ok end,
                            repo: ConsumerRepo,
                            rls_enabled: true
                          )

                 refute_receive :reset_scope, 50
                 :ok
               end,
               repo: ConsumerRepo,
               rls_enabled: true
             )

    assert_receive :set_scope, 1_000
    assert_receive :reset_scope, 1_000
    refute_receive :set_scope, 50
    refute_receive :reset_scope, 50
  end

  test "mixed Mode B and Mode C nesting cannot erase an outer RLS scope" do
    prefix = "consumer_contract_tenant"
    role_name = "consumer_contract_nested_role"
    create_tenant_role!(prefix, role_name)
    on_exit(fn -> drop_tenant_role!(role_name) end)

    mode_b = %Context{
      tenant_id: "consumer-tenant",
      mode: :mode_b,
      bank: "consumer-bank",
      prefix: prefix
    }

    mode_c = %Context{
      tenant_id: "consumer-tenant",
      mode: :mode_c,
      bank: "consumer-bank",
      role_name: role_name,
      prefix: prefix
    }

    assert :ok =
             Tenancy.with_tenant_role(
               mode_c,
               fn ->
                 assert_raise ArgumentError, ~r/cannot nest Mode B/, fn ->
                   Tenancy.with_tenant_role(mode_b, fn -> :ok end,
                     repo: ConsumerRepo,
                     rls_enabled: true
                   )
                 end

                 assert {:ok, %{rows: [[^prefix]]}} =
                          SQL.query(
                            ConsumerRepo,
                            "SELECT current_setting('foresight.tenant_prefix')",
                            []
                          )

                 :ok
               end,
               repo: ConsumerRepo,
               rls_enabled: true
             )

    assert :ok =
             Tenancy.with_tenant_role(
               mode_b,
               fn ->
                 assert_raise ArgumentError, ~r/cannot nest Mode C/, fn ->
                   Tenancy.with_tenant_role(mode_c, fn -> :ok end,
                     repo: ConsumerRepo,
                     rls_enabled: true
                   )
                 end

                 assert {:ok, %{rows: [[^prefix]]}} =
                          SQL.query(
                            ConsumerRepo,
                            "SELECT current_setting('foresight.tenant_prefix')",
                            []
                          )

                 :ok
               end,
               repo: ConsumerRepo,
               rls_enabled: true
             )
  end

  test "distinct migration sources never relink a cached directory in use" do
    source = Migrations.migrations_path()

    scratch =
      Path.join(System.tmp_dir!(), "foresight-cache-test-#{System.unique_integer([:positive])}")

    first = Path.join(scratch, "first")
    second = Path.join(scratch, "second")
    File.mkdir_p!(first)
    File.mkdir_p!(second)

    for filename <- Map.keys(Manifest.entries()) do
      File.cp!(Path.join(source, filename), Path.join(first, filename))
      File.cp!(Path.join(source, filename), Path.join(second, filename))
    end

    on_exit(fn -> File.rm_rf!(scratch) end)

    assert {:ok, _} =
             SchemaProvisioner.provision("consumer_cache_first",
               repo: ConsumerRepo,
               tenant_id: "consumer-cache-first",
               migrations_path: first
             )

    root = :persistent_term.get({SchemaProvisioner, :tenant_migration_cache_root})
    filename = hd(Manifest.files(:tenant))
    first_source = Path.join(first, filename)

    first_link =
      root
      |> Path.join("*/#{filename}")
      |> Path.wildcard()
      |> Enum.find(fn path -> File.read_link(path) == {:ok, first_source} end)

    assert is_binary(first_link)

    assert {:ok, _} =
             SchemaProvisioner.provision("consumer_cache_second",
               repo: ConsumerRepo,
               tenant_id: "consumer-cache-second",
               migrations_path: second
             )

    assert File.read_link(first_link) == {:ok, first_source}
  end

  test "async retain persists and restores only explicit RLS choice" do
    original_engine = Application.get_env(:foresight, :engine)

    start_supervised!(
      {Oban,
       repo: ConsumerRepo,
       name: ConsumerContractOban,
       queues: false,
       plugins: false,
       testing: :manual}
    )

    Application.put_env(:foresight, :engine,
      storage: StorageSpy,
      repo: ConsumerRepo,
      embedder: Foresight.Embedders.Noop,
      llm: Foresight.LLMs.Noop,
      queue: AsyncQueue
    )

    on_exit(fn -> restore_env(:engine, original_engine) end)
    Process.put(:consumer_contract_test, self())

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "async-contract"}

    assert {:ok, %{"operation_id" => operation_id}} =
             AsyncQueue.enqueue_retain(
               ctx,
               %{"items" => [], "async" => true},
               oban_name: ConsumerContractOban,
               rls_enabled: false,
               password: "must-not-persist"
             )

    job = ConsumerRepo.get!(Oban.Job, String.to_integer(operation_id))

    assert job.args["foresight_options"] == %{"rls_enabled" => false}
    refute inspect(job.args) =~ "must-not-persist"

    assert :ok = Foresight.Jobs.RetainWorker.perform(job)
    assert_receive {:worker_opts, opts}
    assert Keyword.fetch!(opts, :rls_enabled) == false
  end

  test "async option serialization omits absent and non-boolean values" do
    assert AsyncOptions.dump(password: "secret") == %{}
    assert AsyncOptions.dump(rls_enabled: "false") == %{}
    assert AsyncOptions.dump(rls_enabled: true, token: "secret") == %{"rls_enabled" => true}
  end

  test "webhook discovery and delivery creation run inside the Mode C RLS scope" do
    prefix = "consumer_contract_webhook"
    role_name = "consumer_contract_webhook_role"
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    assert {:ok, _} =
             Tenancy.provision_mode_c_schema(
               ConsumerRepo,
               "consumer-webhook",
               prefix,
               rls_enabled: true
             )

    create_tenant_role!(prefix, role_name)

    start_supervised!(
      {Oban,
       repo: ConsumerRepo,
       name: ConsumerWebhookOban,
       queues: false,
       plugins: false,
       testing: :manual}
    )

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: ConsumerRepo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: AsyncQueue
    )

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
      drop_tenant_role!(role_name)
    end)

    ctx = %Context{
      tenant_id: "consumer-webhook",
      mode: :mode_c,
      bank: "webhook-bank",
      role_name: role_name,
      prefix: prefix
    }

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, ctx.bank, %{"name" => "Webhook bank"}, rls_enabled: true)

    assert {:ok, _webhook} =
             Foresight.create_webhook(
               ctx,
               ctx.bank,
               %{
                 "url" => "https://example.com/foresight",
                 "event_types" => ["consolidation.completed"]
               },
               rls_enabled: true
             )

    assert :ok =
             Foresight.Webhooks.enqueue_event(
               ctx,
               "consolidation.completed",
               %{"result" => "ok"},
               repo: ConsumerRepo,
               repo_opts: [prefix: prefix],
               oban_name: ConsumerWebhookOban,
               rls_enabled: true
             )

    assert 1 ==
             Tenancy.with_tenant_role(
               ctx,
               fn -> ConsumerRepo.aggregate(Delivery, :count, prefix: prefix) end,
               repo: ConsumerRepo,
               rls_enabled: true
             )

    job = ConsumerRepo.one!(from(job in Oban.Job, order_by: [desc: job.id], limit: 1))
    assert job.args["foresight_options"] == %{"rls_enabled" => true}

    start_supervised!(
      {Oban,
       repo: ConsumerRepo,
       name: ConsumerFailingWebhookOban,
       engine: FailingInsertEngine,
       queues: false,
       plugins: false,
       testing: :manual}
    )

    assert {:error, %Foresight.Error{}} =
             Foresight.Webhooks.enqueue_event(
               ctx,
               "consolidation.completed",
               %{"result" => "failed"},
               repo: ConsumerRepo,
               repo_opts: [prefix: prefix],
               oban_name: ConsumerFailingWebhookOban,
               rls_enabled: true
             )

    assert "failed" ==
             Tenancy.with_tenant_role(
               ctx,
               fn ->
                 ConsumerRepo.one!(
                   from(delivery in Delivery,
                     where: delivery.payload["result"] == "failed",
                     select: delivery.status
                   ),
                   prefix: prefix
                 )
               end,
               repo: ConsumerRepo,
               rls_enabled: true
             )
  end

  defp create_tenant_role!(prefix, role_name) do
    SQL.query!(ConsumerRepo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])
    SQL.query!(ConsumerRepo, ~s|CREATE ROLE "#{role_name}" NOINHERIT|, [])
    SQL.query!(ConsumerRepo, ~s|GRANT "#{role_name}" TO CURRENT_USER|, [])
    SQL.query!(ConsumerRepo, ~s|GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role_name}"|, [])

    SQL.query!(
      ConsumerRepo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      []
    )

    SQL.query!(
      ConsumerRepo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      []
    )
  end

  defp drop_tenant_role!(role_name) do
    SQL.query!(ConsumerRepo, ~s|REVOKE "#{role_name}" FROM CURRENT_USER|, [])
    SQL.query!(ConsumerRepo, ~s|DROP OWNED BY "#{role_name}"|, [])
    SQL.query!(ConsumerRepo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])
  end

  defp role_count do
    {:ok, %{rows: [[count]]}} = SQL.query(ConsumerRepo, "SELECT count(*) FROM pg_roles", [])
    count
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)
end
