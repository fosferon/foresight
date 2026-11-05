defmodule Foresight.Integration.ModeCQualificationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Health
  alias Foresight.HTTP.Router
  alias Foresight.Schemas.TenantLifecycle
  alias Foresight.Tenancy.PostureMonitor
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.Tenancy.TenantKeys
  alias Foresight.TestSupport.PostgresHarness
  alias Oban

  @moduletag :tier2

  # A distinct service (admin) key. Each tenant has its OWN bearer, exercising the
  # production registry path (data-plane calls send the tenant bearer + tenant-id,
  # no role/prefix headers). Role and prefix are resolved server-side.
  @service_key "app-service-key"
  @tenant_a_key "app-key-a"
  @tenant_b_key "app-key-b"
  @bank_id "shared-bank"

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 8,
        after_connect: {Postgrex, :query!, ["RESET ROLE", []]}
      )
    )

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    unless Process.whereis(Foresight.Oban) do
      start_supervised!(
        {Oban,
         name: Foresight.Oban,
         repo: Foresight.Repo,
         peer: false,
         plugins: false,
         testing: :manual,
         queues: [foresight_retain: 2, foresight_consolidate: 2]}
      )
    end

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: Foresight.TestSupport.FakeLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    assert :ok = TenantKeys.delete("tenant-app-a", @tenant_a_key, repo: Foresight.Repo)
    assert :ok = TenantKeys.delete("tenant-app-b", @tenant_b_key, repo: Foresight.Repo)
    TenantKeys.clear_cache()

    tenant_a =
      provision_tenant!("tenant-app-a", "tenant_app_a", "tenant_app_a_app", @tenant_a_key)

    tenant_b =
      provision_tenant!("tenant-app-b", "tenant_app_b", "tenant_app_b_app", @tenant_b_key)

    on_exit(fn ->
      assert :ok = TenantKeys.delete("tenant-app-a", @tenant_a_key, repo: Foresight.Repo)
      assert :ok = TenantKeys.delete("tenant-app-b", @tenant_b_key, repo: Foresight.Repo)
      TenantKeys.clear_cache()
      drop_tenant!(tenant_a)
      drop_tenant!(tenant_b)
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
    end)

    {:ok, tenant_a: tenant_a, tenant_b: tenant_b}
  end

  test "HTTP Mode C keeps same-bank recall isolated under concurrency and exposes the tenant db role",
       %{tenant_a: tenant_a, tenant_b: tenant_b} do
    assert retain_conn(tenant_a, "alpha tenant memory").status == 200
    assert retain_conn(tenant_b, "beta tenant memory").status == 200

    requests =
      Enum.flat_map(1..6, fn _ ->
        [{tenant_a, "alpha tenant"}, {tenant_b, "beta tenant"}]
      end)

    results =
      Task.async_stream(
        requests,
        fn {tenant, query} ->
          conn = recall_conn(tenant, query)
          assert conn.status == 200

          body = Jason.decode!(conn.resp_body)
          [result] = body["results"]

          assert result["text"] == tenant.expected_text

          assert Enum.all?(body["trace"]["strategies"], fn {_name, trace} ->
                   trace["db_role"] == tenant.role_name
                 end)

          :ok
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, :ok}, &1))
    assert {:ok, %{rows: [["postgres"]]}} = SQL.query(Foresight.Repo, "SELECT current_role", [])
  end

  test "HTTP Mode C: a tenant bearer cannot reach another tenant by asserting its id", %{
    tenant_a: tenant_a,
    tenant_b: tenant_b
  } do
    assert retain_conn(tenant_a, "alpha tenant memory").status == 200
    assert retain_conn(tenant_b, "beta tenant memory").status == 200

    # tenant_a's bearer with tenant_b's id. Role and prefix are resolved from the
    # registry, which has no (tenant-app-b, key_a) row — the client cannot assert
    # another tenant's role/prefix via headers, so this is rejected rather than
    # granting cross-tenant access.
    cross = %{tenant_b | api_key: tenant_a.api_key}
    conn = recall_conn(cross, "beta tenant")

    assert conn.status == 401

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "unauthorized",
             "detail" => %{"message" => "unknown tenant credential"}
           }

    assert {:ok, %{rows: [["postgres"]]}} = SQL.query(Foresight.Repo, "SELECT current_role", [])
  end

  test "HTTP Mode C supports helios-diary-style canonical bank bootstrap and targeted deletion",
       %{
         tenant_a: tenant_a
       } do
    canonical_bank_ids = canonical_bank_ids_for(tenant_a.prefix)

    for bank_id <- canonical_bank_ids do
      conn =
        scoped_json_conn(:put, "/v1/default/banks/#{bank_id}", tenant_a, %{
          "name" => bank_id,
          "mission" => "bootstrap mission for #{bank_id}"
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["bank_id"] == bank_id
      assert body["name"] == bank_id
      assert body["mission"] == "bootstrap mission for #{bank_id}"
    end

    list_conn = scoped_conn(:get, "/v1/default/banks", tenant_a)
    assert list_conn.status == 200

    listed_bank_ids =
      list_conn.resp_body
      |> Jason.decode!()
      |> Map.fetch!("banks")
      |> Enum.map(& &1["bank_id"])
      |> Enum.sort()

    assert listed_bank_ids == Enum.sort(canonical_bank_ids)

    [deleted_bank_id | remaining_bank_ids] = canonical_bank_ids

    delete_conn =
      scoped_conn(:delete, "/v1/default/banks/#{deleted_bank_id}", tenant_a)

    assert delete_conn.status == 200

    assert %{
             "success" => true,
             "deleted_count" => 0
           } = Jason.decode!(delete_conn.resp_body)

    list_conn = scoped_conn(:get, "/v1/default/banks", tenant_a)
    assert list_conn.status == 200

    listed_bank_ids =
      list_conn.resp_body
      |> Jason.decode!()
      |> Map.fetch!("banks")
      |> Enum.map(& &1["bank_id"])
      |> Enum.sort()

    assert listed_bank_ids == Enum.sort(remaining_bank_ids)
    assert {:ok, %{rows: [["postgres"]]}} = SQL.query(Foresight.Repo, "SELECT current_role", [])
  end

  test "Mode C posture monitor marks health unhealthy on role drift after warm traffic", %{
    tenant_a: tenant_a,
    tenant_b: tenant_b
  } do
    assert retain_conn(tenant_a, "alpha tenant memory").status == 200
    assert retain_conn(tenant_b, "beta tenant memory").status == 200

    monitor_name = unique_name("PostureMonitor")
    config = posture_monitor_config(monitor_name)
    start_supervised!({PostureMonitor, name: monitor_name, config: config, repo: Foresight.Repo})

    assert %{status: :healthy, probe_count: 2, failures: []} =
             PostureMonitor.run_now(monitor_name)

    assert %{"status" => "healthy"} = Health.check(config)

    revoke_and_drop_role!(tenant_a.prefix, tenant_a.role_name)

    drifted_status = PostureMonitor.run_now(monitor_name)

    assert drifted_status.status == :unhealthy
    assert drifted_status.probe_count == 2

    assert Enum.any?(drifted_status.failures, fn failure ->
             failure.tenant_id == tenant_a.slug and
               String.contains?(failure.message, "does not exist")
           end)

    assert %{
             "status" => "unhealthy",
             "tenancy_posture" => %{"status" => "unhealthy", "probe_count" => 2}
           } = Health.check(config)

    assert recall_conn(tenant_b, "beta tenant").status == 200

    error =
      assert_raise Plug.Conn.WrapperError, fn ->
        recall_conn(tenant_a, "alpha tenant")
      end

    assert Exception.message(error) =~ "does not exist"
    assert {:ok, %{rows: [["postgres"]]}} = SQL.query(Foresight.Repo, "SELECT current_role", [])
  end

  test "Mode C posture monitor stays healthy across tenant deletion churn and deleted tenants fail closed",
       %{tenant_a: tenant_a, tenant_b: tenant_b} do
    assert retain_conn(tenant_a, "alpha tenant memory").status == 200
    assert retain_conn(tenant_b, "beta tenant memory").status == 200

    monitor_name = unique_name("DeletionPostureMonitor")
    config = posture_monitor_config(monitor_name)
    start_supervised!({PostureMonitor, name: monitor_name, config: config, repo: Foresight.Repo})

    assert %{status: :healthy, probe_count: 2, failures: []} =
             PostureMonitor.run_now(monitor_name)

    assert :ok = TenantKeys.delete(tenant_a.slug, tenant_a.api_key, repo: Foresight.Repo)
    TenantKeys.clear_cache()

    assert :ok =
             SchemaProvisioner.drop(tenant_a.prefix,
               repo: Foresight.Repo,
               tenant_id: tenant_a.slug
             )

    status_after_deletion = PostureMonitor.run_now(monitor_name)

    assert status_after_deletion.status == :healthy
    assert status_after_deletion.probe_count == 1
    assert status_after_deletion.failures == []

    assert %{
             "status" => "healthy",
             "tenancy_posture" => %{"status" => "healthy", "probe_count" => 1, "failures" => []}
           } = Health.check(config)

    assert recall_conn(tenant_b, "beta tenant").status == 200

    deleted_tenant_conn = recall_conn(tenant_a, "alpha tenant")
    assert deleted_tenant_conn.status == 401

    assert Jason.decode!(deleted_tenant_conn.resp_body) == %{
             "error" => "unauthorized",
             "detail" => %{
               "message" => "unknown tenant credential"
             }
           }

    deleted_tenant_list_conn = scoped_conn(:get, "/v1/default/banks", tenant_a)
    assert deleted_tenant_list_conn.status == 401

    assert Jason.decode!(deleted_tenant_list_conn.resp_body) == %{
             "error" => "unauthorized",
             "detail" => %{
               "message" => "unknown tenant credential"
             }
           }

    assert {:ok, %{rows: [["postgres"]]}} = SQL.query(Foresight.Repo, "SELECT current_role", [])
  end

  defp retain_conn(tenant, text) do
    scoped_json_conn(:post, "/v1/default/banks/#{@bank_id}/memories", tenant, %{
      "async" => false,
      "items" => [
        %{"content" => text, "context" => "chat", "type" => "world"}
      ]
    })
  end

  defp recall_conn(tenant, query) do
    scoped_json_conn(:post, "/v1/default/banks/#{@bank_id}/memories/recall", tenant, %{
      "query" => query,
      "trace" => true
    })
  end

  defp scoped_json_conn(method, path, tenant, body) do
    # Production data-plane shape: tenant bearer + tenant-id only. No role/prefix
    # headers — the server resolves them from the registry.
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{tenant.api_key}")
      |> put_req_header("x-foresight-tenant-id", tenant.slug)

    Router.call(conn, router_opts())
  end

  defp scoped_conn(method, path, tenant) do
    conn =
      conn(method, path)
      |> put_req_header("authorization", "Bearer #{tenant.api_key}")
      |> put_req_header("x-foresight-tenant-id", tenant.slug)

    Router.call(conn, router_opts())
  end

  defp router_opts do
    Router.init(
      config: %{
        auth: %{request_api_key: @service_key},
        file_ingestion: %{enabled: false},
        http: %{enabled: true, tenant_resolver: nil, tenant_resolver_opts: []},
        ml: %{enabled: false},
        oban: %{enabled: true},
        repo: %{enabled: true, module: Foresight.Repo}
      }
    )
  end

  defp provision_tenant!(slug, prefix, role_name, api_key) do
    cleanup_tenant_identity!(slug, prefix, role_name)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo, tenant_id: slug)
    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "#{role_name}" NOINHERIT|, [])
    SQL.query!(Foresight.Repo, ~s|GRANT "#{role_name}" TO CURRENT_USER|, [])
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

    assert {:ok, _tenant_key} =
             TenantKeys.put(slug, api_key, role_name, repo: Foresight.Repo, prefix: prefix)

    %{
      slug: slug,
      prefix: prefix,
      role_name: role_name,
      api_key: api_key,
      expected_text:
        case slug do
          "tenant-app-a" -> "alpha tenant memory"
          "tenant-app-b" -> "beta tenant memory"
        end
    }
  end

  defp drop_tenant!(tenant) do
    cleanup_tenant_identity!(tenant.slug, tenant.prefix, tenant.role_name)
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

  defp posture_monitor_config(name) do
    %{
      repo: %{enabled: true, module: Foresight.Repo},
      tenancy: %{
        enabled: true,
        rls_enabled: true,
        posture_monitor: %{
          enabled: true,
          module: PostureMonitor,
          name: name,
          interval_ms: 60_000
        }
      }
    }
  end

  defp canonical_bank_ids_for(prefix) do
    env = "test"

    for kind <- ~w(psych_profile vrg session_synthesis facts) do
      "app_#{env}_#{prefix}__#{kind}"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)

  defp unique_name(suffix) do
    Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
  end

  defp cleanup_tenant_identity!(slug, prefix, role_name) do
    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo, tenant_id: slug)

    _ =
      Foresight.Repo.delete_all(
        from(lifecycle in TenantLifecycle, where: lifecycle.tenant_id == ^prefix)
      )

    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])
  end
end
