defmodule Foresight.HTTP.Auth do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.ErrorTranslator

  @doc """
  Data-route authentication.

  Captures the presented bearer token into `conn.assigns[:api_key]` so the request
  resolver can authorize it (service key vs. tenant-key registry). This plug is a
  gate for *presence* of a credential, not authority: when a service key is
  configured, a request with no bearer is rejected here; a present token is passed
  through and authorized downstream by `Foresight.HTTP.RequestContext`.

  There is no bearer passthrough: an unrecognized token is not "authenticated" — it
  simply reaches the resolver, which rejects it unless it matches the service key or
  resolves in the tenant-key registry.
  """
  @spec authenticate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authenticate(conn, %{auth: auth}) when is_map(auth) do
    expected = expected_key(auth)

    case bearer_token(conn) do
      token when is_binary(token) and token != "" ->
        assign(conn, :api_key, token)

      _ ->
        if is_nil(expected) do
          # No service key configured (dev/open). Preflight forbids this when HTTP
          # is enabled in a real deployment; see Foresight.Config.preflight!/1.
          assign(conn, :api_key, nil)
        else
          unauthorized(conn)
        end
    end
  end

  def authenticate(conn, _config), do: assign(conn, :api_key, nil)

  @doc """
  Strict service-key authentication for admin endpoints (e.g. tenant provisioning).

  Requires the presented bearer to equal the configured service key, compared in
  constant time. Never honors a tenant credential.
  """
  @spec authenticate_service(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def authenticate_service(conn, %{auth: auth}) when is_map(auth) do
    expected = expected_key(auth)
    token = bearer_token(conn)

    if is_binary(expected) and expected != "" and is_binary(token) and
         Plug.Crypto.secure_compare(token, expected) do
      assign(conn, :api_key, token)
    else
      unauthorized(conn)
    end
  end

  def authenticate_service(conn, _config), do: unauthorized(conn)

  @doc """
  Whether the given api key is the configured service (admin) credential.

  Header impersonation (asserting an arbitrary role/prefix) is reserved for service
  callers, so this gate is strict. When no service key is configured (the open
  dev/test posture), a *presented* bearer is NOT promoted to service — it falls
  through to the tenant-key registry, which rejects it. Only a genuinely absent
  credential is the anonymous Mode A caller; otherwise a random bearer plus forged
  headers would resurrect the cross-tenant escape.
  """
  @spec service_credential?(map(), String.t() | nil) :: boolean()
  def service_credential?(config, api_key) do
    auth = Map.get(config, :auth) || %{}
    expected = expected_key(auth)

    cond do
      is_nil(expected) or expected == "" -> is_nil(api_key) or api_key == ""
      is_binary(api_key) -> Plug.Crypto.secure_compare(api_key, expected)
      true -> false
    end
  end

  defp expected_key(%{request_api_key: request_api_key})
       when is_binary(request_api_key) and request_api_key != "",
       do: request_api_key

  defp expected_key(%{api_key: api_key}), do: normalize_key(api_key)
  defp expected_key(_auth), do: nil

  defp normalize_key(nil), do: nil
  defp normalize_key(""), do: nil
  defp normalize_key(api_key) when is_binary(api_key), do: api_key

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> token
      _ -> nil
    end
  end

  defp unauthorized(conn) do
    conn
    |> ErrorTranslator.send_error(Error.new(:unauthorized, %{message: "invalid bearer token"}))
    |> halt()
  end
end
