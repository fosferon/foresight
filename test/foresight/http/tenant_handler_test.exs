defmodule Foresight.HTTP.TenantHandlerTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.HTTP.Router
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.Tenancy.TenantKeys
  alias Foresight.TestSupport.PostgresHarness

  @service_key "foresight-service-key"

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
    TenantKeys.clear_cache()
    cleanup_tenant!("tenant-http", "tenant_http", "tenant_http_app", "tenant-secret")
    :ok
  end

  test "service-authenticated provision endpoint creates the mode-c tenant contract" do
    conn =
      json_conn(:put, "/_foresight/tenants/tenant-http", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "tenant" => %{
               "tenant_id" => "tenant-http",
               "prefix" => "tenant_http",
               "role_name" => "tenant_http_app"
             }
           }

    assert SchemaProvisioner.schema_exists?("tenant_http", repo: Foresight.Repo)

    assert {:ok, "tenant_http_app"} =
             TenantKeys.resolve_role("tenant-http", "tenant-secret", repo: Foresight.Repo)

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT 1 FROM pg_roles WHERE rolname = $1",
               ["tenant_http_app"]
             )
  end

  test "service-authenticated show endpoint returns tenant lifecycle status and role metadata" do
    provision_tenant!()

    conn =
      conn(:get, "/_foresight/tenants/tenant-http")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)

    assert body["tenant"]["tenant_id"] == "tenant-http"
    assert body["tenant"]["prefix"] == "tenant_http"
    assert body["tenant"]["status"] == "provisioned"
    assert body["tenant"]["role_name"] == "tenant_http_app"
    assert body["tenant"]["metadata"]["role_name"] == "tenant_http_app"
    assert is_binary(body["tenant"]["inserted_at"])
    assert is_binary(body["tenant"]["updated_at"])
    assert is_binary(body["tenant"]["last_provisioned_at"])
  end

  test "service-authenticated show endpoint returns deleted lifecycle after tenant drop" do
    provision_tenant!()

    conn =
      json_conn(:post, "/_foresight/tenants/tenant-http/drop", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200

    show_conn =
      conn(:get, "/_foresight/tenants/tenant-http")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert show_conn.status == 200

    body = Jason.decode!(show_conn.resp_body)

    assert body["tenant"]["tenant_id"] == "tenant-http"
    assert body["tenant"]["prefix"] == "tenant_http"
    assert body["tenant"]["status"] == "deleted"
    assert body["tenant"]["role_name"] == "tenant_http_app"
    assert is_binary(body["tenant"]["last_deleted_at"])
  end

  test "service-authenticated drop endpoint tears down the mode-c tenant contract" do
    provision_tenant!()

    conn =
      json_conn(:post, "/_foresight/tenants/tenant-http/drop", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "tenant" => %{
               "tenant_id" => "tenant-http",
               "prefix" => "tenant_http",
               "role_name" => "tenant_http_app"
             }
           }

    refute SchemaProvisioner.schema_exists?("tenant_http", repo: Foresight.Repo)

    assert {:error, :not_found} =
             TenantKeys.resolve_role("tenant-http", "tenant-secret", repo: Foresight.Repo)

    assert {:ok, %{num_rows: 0}} =
             SQL.query(
               Foresight.Repo,
               "SELECT 1 FROM pg_roles WHERE rolname = $1",
               ["tenant_http_app"]
             )
  end

  test "service-authenticated drop endpoint removes all tenant key hashes for the tenant slug" do
    provision_tenant!()

    assert {:ok, _tenant_key} =
             TenantKeys.put_hashed(
               "tenant-http",
               TenantKeys.hash_api_key("tenant-secret-rotated"),
               "tenant_http_app",
               repo: Foresight.Repo
             )

    conn =
      json_conn(:post, "/_foresight/tenants/tenant-http/drop", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200

    assert {:error, :not_found} =
             TenantKeys.resolve_role("tenant-http", "tenant-secret", repo: Foresight.Repo)

    assert {:error, :not_found} =
             TenantKeys.resolve_role("tenant-http", "tenant-secret-rotated", repo: Foresight.Repo)
  end

  test "service-authenticated drop endpoint removes an active tenant role after bank writes" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_tenancy = Application.get_env(:foresight, :tenancy)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine, %{
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    })

    Application.put_env(:foresight, :tenancy, %{enabled: true, rls_enabled: true})

    on_exit(fn ->
      restore_foresight_env(:backend, original_backend)
      restore_foresight_env(:engine, original_engine)
      restore_foresight_env(:tenancy, original_tenancy)
    end)

    provision_tenant!()

    ctx = %Context{
      tenant_id: "tenant-http",
      mode: :mode_c,
      bank: "tenant_http_facts",
      prefix: "tenant_http",
      role_name: "tenant_http_app"
    }

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "tenant_http_facts", %{"name" => "Tenant Facts"})

    assert {:ok, _result} =
             Foresight.retain(ctx, %{
               "items" => [%{"content" => "tenant http fact", "context" => "general"}],
               "async" => false
             })

    conn =
      json_conn(:post, "/_foresight/tenants/tenant-http/drop", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200
    refute SchemaProvisioner.schema_exists?("tenant_http", repo: Foresight.Repo)

    assert {:ok, %{num_rows: 0}} =
             SQL.query(
               Foresight.Repo,
               "SELECT 1 FROM pg_roles WHERE rolname = $1",
               ["tenant_http_app"]
             )
  end

  test "service-authenticated drop endpoint succeeds when the tenant role is already absent" do
    provision_tenant!()

    for statement <- [
          ~s|ALTER DEFAULT PRIVILEGES IN SCHEMA "tenant_http" REVOKE ALL PRIVILEGES ON TABLES FROM "tenant_http_app"|,
          ~s|ALTER DEFAULT PRIVILEGES IN SCHEMA "tenant_http" REVOKE ALL PRIVILEGES ON SEQUENCES FROM "tenant_http_app"|,
          ~s|REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA "tenant_http" FROM "tenant_http_app"|,
          ~s|REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA "tenant_http" FROM "tenant_http_app"|,
          ~s|REVOKE ALL PRIVILEGES ON SCHEMA "tenant_http" FROM "tenant_http_app"|,
          ~s|DROP OWNED BY "tenant_http_app"|,
          ~s|DROP ROLE IF EXISTS "tenant_http_app"|
        ] do
      assert {:ok, _} = SQL.query(Foresight.Repo, statement, [])
    end

    conn =
      json_conn(:post, "/_foresight/tenants/tenant-http/drop", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 200
    refute SchemaProvisioner.schema_exists?("tenant_http", repo: Foresight.Repo)

    assert {:error, :not_found} =
             TenantKeys.resolve_role("tenant-http", "tenant-secret", repo: Foresight.Repo)
  end

  test "tenant bearer cannot hit the service lifecycle endpoint even when passthrough is globally enabled" do
    conn =
      json_conn(:put, "/_foresight/tenants/tenant-http", %{
        "prefix" => "tenant_http",
        "role_name" => "tenant_http_app",
        "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
      })
      |> Plug.Conn.put_req_header("authorization", "Bearer tenant-secret")
      |> Router.call(
        Router.init(
          config: %{
            auth: %{
              api_key: @service_key,
              allow_bearer_passthrough: true
            },
            http: %{enabled: true},
            ml: %{enabled: false},
            oban: %{enabled: false},
            repo: %{enabled: true, module: Foresight.Repo},
            tenancy: %{enabled: true, rls_enabled: true}
          }
        )
      )

    assert conn.status == 401

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "unauthorized",
             "detail" => %{"message" => "invalid bearer token"}
           }
  end

  test "service-authenticated show endpoint returns 404 for an unknown tenant" do
    conn =
      conn(:get, "/_foresight/tenants/tenant-missing")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@service_key}")
      |> Router.call(router_opts())

    assert conn.status == 404

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "not_found",
             "detail" => %{"message" => "tenant not found"}
           }
  end

  defp provision_tenant! do
    assert {:ok, _tenant} =
             Foresight.Tenancy.ModeCTenantLifecycle.provision(
               "tenant-http",
               %{
                 "prefix" => "tenant_http",
                 "role_name" => "tenant_http_app",
                 "api_key_hash" => TenantKeys.hash_api_key("tenant-secret")
               },
               repo: Foresight.Repo,
               rls_enabled: true
             )
  end

  defp cleanup_tenant!(tenant_id, prefix, role_name, api_key) do
    _ = TenantKeys.delete(tenant_id, api_key, repo: Foresight.Repo)

    _ =
      SchemaProvisioner.drop(prefix,
        repo: Foresight.Repo,
        rls_enabled: true,
        tenant_id: tenant_id
      )

    _ = SQL.query(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{role_name}"|, [])
  end

  defp router_opts do
    Router.init(
      config: %{
        auth: %{api_key: @service_key, allow_bearer_passthrough: true},
        http: %{enabled: true},
        ml: %{enabled: false},
        oban: %{enabled: false},
        repo: %{enabled: true, module: Foresight.Repo},
        tenancy: %{enabled: true, rls_enabled: true}
      }
    )
  end

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  # Restore an app-env section without poisoning it: when the original value was unset,
  # delete the key rather than writing `nil`. A section left as `nil` in the global env
  # leaks into Config.resolve/1 for every later test.
  defp restore_foresight_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_foresight_env(key, value), do: Application.put_env(:foresight, key, value)
end
