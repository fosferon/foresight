defmodule Foresight.HTTP.RequestContextModeCTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.HTTP.RequestContext
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.Tenancy.TenantKeys
  alias Foresight.TestSupport.PostgresHarness

  # A distinct service (admin) key. Tenant callers present a *different* bearer
  # ("secret"), so they exercise the registry path — role + prefix are resolved
  # server-side, never trusted from a client header.
  @service_key "svc-key"
  @tenant_slug "tenant-http"
  @tenant_key "secret"
  @tenant_prefix "tenant_http"
  @tenant_role "tenant_http_reader"

  defmodule FailingTenantKeyRepo do
    def one(_query) do
      raise DBConnection.ConnectionError.exception(message: "tenant key repo unavailable")
    end
  end

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])
    public_repo_config = Application.get_env(:foresight, Foresight.PublicRepo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 10)
    )

    Application.put_env(
      :foresight,
      Foresight.PublicRepo,
      Keyword.merge(public_repo_config, url: harness.url, pool_size: 2)
    )

    start_supervised!(Foresight.Repo)
    start_supervised!(Foresight.PublicRepo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      Application.put_env(:foresight, Foresight.PublicRepo, public_repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    assert :ok = TenantKeys.delete(@tenant_slug, @tenant_key, repo: Foresight.Repo)
    assert :ok = TenantKeys.delete(@tenant_slug, @tenant_key, repo: Foresight.PublicRepo)
    TenantKeys.clear_cache()
    :ok
  end

  # --- helpers -------------------------------------------------------------

  defp base_config(repo_config) do
    %{
      http: %{enabled: true, tenant_resolver: nil, tenant_resolver_opts: []},
      repo: repo_config,
      auth: %{request_api_key: @service_key}
    }
  end

  defp tenant_conn(repo_config) do
    conn(:get, "/v1/default/banks/fosferon/memories/list")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{@tenant_key}")
    |> Plug.Conn.put_req_header("x-foresight-tenant-id", @tenant_slug)
    |> Plug.Conn.assign(:api_key, @tenant_key)
    |> Plug.Conn.put_private(:foresight_config, base_config(repo_config))
  end

  defp register_tenant_key!(repo \\ Foresight.Repo) do
    assert {:ok, _} =
             TenantKeys.put(@tenant_slug, @tenant_key, @tenant_role,
               repo: repo,
               prefix: @tenant_prefix
             )
  end

  # --- registry path -------------------------------------------------------

  test "resolve returns mode_c and derives role + prefix from the tenant key registry" do
    register_tenant_key!()

    assert {:ok,
            %Context{
              tenant_id: @tenant_slug,
              mode: :mode_c,
              bank: "fosferon",
              prefix: @tenant_prefix,
              role_name: @tenant_role
            }} =
             RequestContext.resolve(
               tenant_conn(%{enabled: true, module: Foresight.Repo}),
               "fosferon"
             )
  end

  test "resolve is unauthorized when the credential has no registry row" do
    assert {:error,
            %Error{reason: :unauthorized, detail: %{message: "unknown tenant credential"}}} =
             RequestContext.resolve(
               tenant_conn(%{enabled: true, module: Foresight.Repo}),
               "fosferon"
             )
  end

  test "resolve fails with service_unavailable when the registry lookup cannot reach the repo" do
    assert {:error,
            %Error{
              reason: :service_unavailable,
              detail: %{
                message: "tenant key registry lookup failed",
                detail: "tenant key repo unavailable"
              }
            }} =
             RequestContext.resolve(
               tenant_conn(%{enabled: true, module: FailingTenantKeyRepo}),
               "fosferon"
             )
  end

  test "resolve serves the cached identity when the repo later becomes unavailable" do
    register_tenant_key!()

    assert {:ok, %Context{mode: :mode_c, role_name: @tenant_role, prefix: @tenant_prefix}} =
             RequestContext.resolve(
               tenant_conn(%{enabled: true, module: Foresight.Repo}),
               "fosferon"
             )

    # Same credential, now with an unreachable repo: role AND prefix come from cache.
    assert {:ok, %Context{mode: :mode_c, role_name: @tenant_role, prefix: @tenant_prefix}} =
             RequestContext.resolve(
               tenant_conn(%{enabled: true, module: FailingTenantKeyRepo}),
               "fosferon"
             )
  end

  test "resolve prefers the dedicated public repo for tenant key lookups" do
    register_tenant_key!(Foresight.PublicRepo)

    repo_config = %{
      enabled: true,
      module: FailingTenantKeyRepo,
      public: %{enabled: true, module: Foresight.PublicRepo}
    }

    assert {:ok, %Context{mode: :mode_c, role_name: @tenant_role, prefix: @tenant_prefix}} =
             RequestContext.resolve(tenant_conn(repo_config), "fosferon")
  end

  test "invalidating a cached tenant key forces a fresh repo lookup" do
    register_tenant_key!()
    repo_config = %{enabled: true, module: Foresight.Repo}

    assert {:ok, %Context{role_name: @tenant_role}} =
             RequestContext.resolve(tenant_conn(repo_config), "fosferon")

    # Re-point the same credential to a new role; put_hashed invalidates the cache.
    assert {:ok, _} =
             TenantKeys.put(@tenant_slug, @tenant_key, "#{@tenant_role}_v2",
               repo: Foresight.Repo,
               prefix: @tenant_prefix
             )

    assert {:ok, %Context{role_name: role}} =
             RequestContext.resolve(tenant_conn(repo_config), "fosferon")

    assert role == "#{@tenant_role}_v2"
  end

  test "deleting a tenant key fails closed on the next request" do
    register_tenant_key!()
    repo_config = %{enabled: true, module: Foresight.Repo}

    assert {:ok, %Context{mode: :mode_c, role_name: @tenant_role}} =
             RequestContext.resolve(tenant_conn(repo_config), "fosferon")

    assert :ok = TenantKeys.delete(@tenant_slug, @tenant_key, repo: Foresight.Repo)

    assert {:error,
            %Error{reason: :unauthorized, detail: %{message: "unknown tenant credential"}}} =
             RequestContext.resolve(tenant_conn(repo_config), "fosferon")
  end

  # --- diagnostics ---------------------------------------------------------

  test "runtime request-context diagnostic reports the active db role and tenant prefix" do
    original_tenancy = Application.get_env(:foresight, :tenancy)
    Application.put_env(:foresight, :tenancy, rls_enabled: true)

    tenant =
      provision_mode_c_tenant!(@tenant_slug, @tenant_prefix, @tenant_role, @tenant_key)

    on_exit(fn ->
      drop_mode_c_tenant!(tenant)
      restore_env(:tenancy, original_tenancy)
    end)

    config = %{
      http: %{
        enabled: true,
        diagnostics: %{enabled: true},
        tenant_resolver: nil,
        tenant_resolver_opts: []
      },
      repo: %{enabled: true, module: Foresight.Repo},
      auth: %{request_api_key: @service_key}
    }

    conn =
      conn(:get, "/_foresight/runtime/request-context/fosferon")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@tenant_key}")
      |> Plug.Conn.put_req_header("x-foresight-tenant-id", @tenant_slug)
      |> Plug.Conn.assign(:api_key, @tenant_key)
      |> Foresight.HTTP.Router.call(Foresight.HTTP.Router.init(config: config))

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "tenant_id" => @tenant_slug,
             "mode" => "mode_c",
             "bank" => "fosferon",
             "prefix" => tenant.prefix,
             "role_name" => tenant.role_name,
             "db_role" => tenant.role_name,
             "db_tenant_prefix" => tenant.prefix
           }
  end

  test "runtime request-context diagnostic returns 404 when diagnostics are disabled" do
    config = %{
      http: %{enabled: true, diagnostics: %{enabled: false}},
      repo: %{enabled: false},
      auth: %{api_key: nil}
    }

    conn =
      conn(:get, "/_foresight/runtime/request-context/fosferon")
      |> Foresight.HTTP.Router.call(Foresight.HTTP.Router.init(config: config))

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  # --- provisioning helpers ------------------------------------------------

  defp provision_mode_c_tenant!(slug, prefix, role_name, api_key) do
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

    SQL.query!(Foresight.Repo, ~s|GRANT "#{role_name}" TO CURRENT_USER|, [])

    assert {:ok, _tenant_key} =
             TenantKeys.put(slug, api_key, role_name, repo: Foresight.Repo, prefix: prefix)

    %{slug: slug, prefix: prefix, role_name: role_name, api_key: api_key}
  end

  defp drop_mode_c_tenant!(tenant) do
    assert :ok = TenantKeys.delete(tenant.slug, tenant.api_key, repo: Foresight.Repo)
    TenantKeys.clear_cache()

    _ =
      SchemaProvisioner.drop(tenant.prefix,
        repo: Foresight.Repo,
        rls_enabled: true,
        tenant_id: tenant.slug
      )

    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{tenant.role_name}"|, [])
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)
end
