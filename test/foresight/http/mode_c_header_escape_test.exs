defmodule Foresight.HTTP.ModeCHeaderEscapeTest do
  @moduledoc """
  Regression tests for the Mode C request-layer trust boundary.

  These do NOT touch a database. They exercise Auth.authenticate/2 and the
  RequestContext resolver — the layer that decides which tenant role/schema a
  request may assume.

  History: this file originally reproduced a confirmed cross-tenant escape — a
  client-supplied `x-foresight-role` header was trusted verbatim, and under bearer
  passthrough any non-empty token authenticated. These tests now assert the fixed,
  fail-closed behavior:

    * a non-service ("tenant") caller cannot assert a role/prefix via headers; role
      and prefix are resolved server-side (registry + lifecycle), so forged headers
      are ignored and an unknown credential is rejected rather than granted Mode C;
    * the service (admin) caller may still assert role/prefix headers — the ops/test
      impersonation path — but that requires the real service key, which passthrough
      no longer fabricates.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.RequestContext

  # A service key IS configured (the production posture). Passthrough is gone.
  defp service_config do
    %{
      auth: %{request_api_key: "foresight-service-key", tenant_scopes: %{}},
      http: %{},
      repo: %{module: Foresight.Repo}
    }
  end

  defp authed(conn, config) do
    conn
    |> Plug.Conn.put_private(:foresight_config, config)
    |> Auth.authenticate(config)
  end

  describe "forged headers from a tenant/random token (the old escape)" do
    test "a random bearer + forged role/prefix does NOT grant Mode C on a victim tenant" do
      config = service_config()

      conn =
        conn(:post, "/v1/victim/banks/default/memories/recall")
        |> Plug.Conn.put_req_header("authorization", "Bearer totally-not-the-service-key")
        |> Plug.Conn.put_req_header("x-foresight-tenant-id", "victim_tenant")
        |> Plug.Conn.put_req_header("x-foresight-prefix", "victim_schema")
        |> Plug.Conn.put_req_header("x-foresight-role", "victim_role")
        |> authed(config)

      # The token is captured (no passthrough decision at the auth layer)...
      refute conn.halted
      # ...but it is not the service key, so the forged role/prefix headers are
      # ignored and the credential is resolved against the registry, which denies it.
      assert {:error, %Error{}} = RequestContext.resolve(conn, "default")

      refute match?(
               {:ok, %Context{mode: :mode_c, role_name: "victim_role"}},
               RequestContext.resolve(conn, "default")
             )
    end

    test "a random bearer with no tenant scoping is not authorized for global scope" do
      config = service_config()

      conn =
        conn(:get, "/v1/default/banks/default/memories/list")
        |> Plug.Conn.put_req_header("authorization", "Bearer totally-not-the-service-key")
        |> authed(config)

      assert {:error, %Error{}} = RequestContext.resolve(conn, "default")
    end
  end

  describe "service (admin) caller keeps the impersonation path" do
    test "the real service key may assert role/prefix headers → Mode C" do
      config = service_config()

      conn =
        conn(:post, "/v1/tenant/banks/default/memories/recall")
        |> Plug.Conn.put_req_header("authorization", "Bearer foresight-service-key")
        |> Plug.Conn.put_req_header("x-foresight-tenant-id", "tenant_a")
        |> Plug.Conn.put_req_header("x-foresight-prefix", "tenant_a_schema")
        |> Plug.Conn.put_req_header("x-foresight-role", "tenant_a_role")
        |> authed(config)

      refute conn.halted
      assert {:ok, %Context{mode: :mode_c} = ctx} = RequestContext.resolve(conn, "default")
      assert ctx.role_name == "tenant_a_role"
      assert ctx.prefix == "tenant_a_schema"
    end

    test "the service key with no tenant headers resolves to Mode A (global)" do
      config = service_config()

      conn =
        conn(:get, "/v1/default/banks/default/memories/list")
        |> Plug.Conn.put_req_header("authorization", "Bearer foresight-service-key")
        |> authed(config)

      assert {:ok, %Context{mode: :mode_a}} = RequestContext.resolve(conn, "default")
    end
  end

  describe "dev/open posture (no service key configured)" do
    # Finding 1: without a service key, a *presented* bearer must not be promoted to
    # service — otherwise forged role/prefix headers resurrect the cross-tenant escape.
    defp open_config do
      %{auth: %{api_key: nil}, http: %{}, repo: %{module: Foresight.Repo}}
    end

    test "a random bearer + forged headers does NOT get Mode C in open posture" do
      config = open_config()

      conn =
        conn(:post, "/v1/victim/banks/default/memories/recall")
        |> Plug.Conn.put_req_header("authorization", "Bearer anything")
        |> Plug.Conn.put_req_header("x-foresight-tenant-id", "victim")
        |> Plug.Conn.put_req_header("x-foresight-prefix", "victim_schema")
        |> Plug.Conn.put_req_header("x-foresight-role", "victim_role")
        |> authed(config)

      assert {:error, %Error{}} = RequestContext.resolve(conn, "default")

      refute match?(
               {:ok, %Context{mode: :mode_c, role_name: "victim_role"}},
               RequestContext.resolve(conn, "default")
             )
    end

    test "a truly anonymous request (no bearer) is Mode A in open posture" do
      config = open_config()

      conn =
        conn(:get, "/v1/default/banks/default/memories/list")
        |> authed(config)

      assert {:ok, %Context{mode: :mode_a}} = RequestContext.resolve(conn, "default")
    end
  end

  describe "missing credential" do
    test "no bearer is rejected when a service key is configured" do
      config = service_config()

      conn =
        conn(:get, "/v1/default/banks/default/memories/list")
        |> authed(config)

      assert conn.halted, "missing bearer must be rejected when a service key is configured"
    end
  end
end
