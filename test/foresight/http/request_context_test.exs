defmodule Foresight.HTTP.RequestContextTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.HTTP.RequestContext

  test "resolve returns mode_b when an authenticated request provides a tenant prefix" do
    conn =
      conn(:get, "/v1/default/banks/fosferon/memories/list")
      |> Plug.Conn.put_req_header("authorization", "Bearer secret")
      |> Plug.Conn.put_req_header("x-foresight-tenant-id", "tenant-http")
      |> Plug.Conn.put_req_header("x-foresight-prefix", "tenant_http")
      |> Plug.Conn.assign(:api_key, "secret")
      |> Plug.Conn.put_private(:foresight_config, %{
        http: %{enabled: true, tenant_resolver: nil, tenant_resolver_opts: []},
        auth: %{
          api_key: "secret",
          tenant_scopes: %{
            "secret" => %{
              tenant_ids: ["tenant-http"],
              prefixes: ["tenant_http"]
            }
          }
        }
      })

    assert {:ok,
            %Context{
              tenant_id: "tenant-http",
              mode: :mode_b,
              bank: "fosferon",
              prefix: "tenant_http",
              role_name: nil
            }} = RequestContext.resolve(conn, "fosferon")
  end

  test "resolve rejects invalid tenant schema prefixes" do
    conn =
      conn(:get, "/v1/default/banks/fosferon/memories/list")
      |> Plug.Conn.put_req_header("authorization", "Bearer secret")
      |> Plug.Conn.put_req_header("x-foresight-tenant-id", "tenant-http")
      |> Plug.Conn.put_req_header("x-foresight-prefix", "tenant-http;drop schema")
      |> Plug.Conn.assign(:api_key, "secret")
      |> Plug.Conn.put_private(:foresight_config, %{
        http: %{enabled: true, tenant_resolver: nil, tenant_resolver_opts: []},
        auth: %{api_key: "secret", tenant_scopes: %{}}
      })

    assert {:error,
            %Error{
              reason: :invalid_request,
              detail: %{message: "invalid tenant schema prefix"}
            }} =
             RequestContext.resolve(conn, "fosferon")
  end
end
