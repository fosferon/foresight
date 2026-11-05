defmodule Foresight.HTTP.AuthTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Foresight.HTTP.Auth

  @service_config %{auth: %{request_api_key: "foresight-service-key"}}

  describe "authenticate/2 (data-route token capture)" do
    test "captures a presented bearer so the resolver can authorize it" do
      conn =
        conn(:get, "/v1/default/banks/fosferon")
        |> Plug.Conn.put_req_header("authorization", "Bearer tenant-secret")
        |> Auth.authenticate(@service_config)

      # Capture, do not authorize here. There is no passthrough: an unrecognized
      # token is not "authenticated" — the resolver rejects it unless it is the
      # service key or resolves in the tenant-key registry.
      refute conn.halted
      assert conn.assigns.api_key == "tenant-secret"
    end

    test "captures the service bearer" do
      conn =
        conn(:get, "/v1/default/banks/fosferon")
        |> Plug.Conn.put_req_header("authorization", "Bearer foresight-service-key")
        |> Auth.authenticate(@service_config)

      refute conn.halted
      assert conn.assigns.api_key == "foresight-service-key"
    end

    test "rejects a missing bearer when a service key is configured" do
      conn =
        conn(:get, "/v1/default/banks/fosferon")
        |> Auth.authenticate(@service_config)

      assert conn.halted
      assert conn.status == 401
    end

    test "allows a missing bearer only when no service key is configured (dev/open)" do
      conn =
        conn(:get, "/v1/default/banks/fosferon")
        |> Auth.authenticate(%{auth: %{api_key: nil}})

      refute conn.halted
      assert conn.assigns.api_key == nil
    end
  end

  describe "authenticate_service/2 (admin endpoints)" do
    test "accepts only the exact service key" do
      conn =
        conn(:put, "/_foresight/tenants/t1")
        |> Plug.Conn.put_req_header("authorization", "Bearer foresight-service-key")
        |> Auth.authenticate_service(@service_config)

      refute conn.halted
      assert conn.assigns.api_key == "foresight-service-key"
    end

    test "rejects a tenant token even when it is a valid registry credential elsewhere" do
      conn =
        conn(:put, "/_foresight/tenants/t1")
        |> Plug.Conn.put_req_header("authorization", "Bearer tenant-secret")
        |> Auth.authenticate_service(@service_config)

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "service_credential?/2" do
    test "true only for the exact service key" do
      assert Auth.service_credential?(@service_config, "foresight-service-key")
      refute Auth.service_credential?(@service_config, "tenant-secret")
      refute Auth.service_credential?(@service_config, nil)
    end

    test "with no service key configured, only an absent credential is anonymous (not any token)" do
      # A presented bearer must NOT be promoted to service just because no key is
      # configured — otherwise a random token + forged headers resurrects the escape.
      refute Auth.service_credential?(%{auth: %{api_key: nil}}, "anything")
      assert Auth.service_credential?(%{auth: %{api_key: nil}}, nil)
      assert Auth.service_credential?(%{auth: %{api_key: nil}}, "")
    end
  end
end
