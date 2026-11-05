defmodule Foresight.HTTP.Handlers.TenantHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.Tenancy.ModeCTenantLifecycle

  @spec provision(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def provision(conn, tenant_id) do
    run(conn, tenant_id, &ModeCTenantLifecycle.provision/3)
  end

  @spec show(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def show(conn, tenant_id) do
    with_authenticated(conn, fn conn ->
      repo = get_in(auth_config(conn), [:repo, :module]) || Foresight.Repo

      case ModeCTenantLifecycle.fetch(tenant_id, repo: repo) do
        {:ok, result} ->
          json(conn, 200, %{"tenant" => stringify(result)})

        {:error, :not_found} ->
          ErrorTranslator.send_error(
            conn,
            Error.new(:not_found, %{message: "tenant not found"})
          )
      end
    end)
  end

  @spec drop(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def drop(conn, tenant_id) do
    run(conn, tenant_id, &ModeCTenantLifecycle.drop/3)
  end

  defp run(conn, tenant_id, fun) do
    with_authenticated(conn, fn conn ->
      case parse_payload(conn.body_params) do
        {:ok, payload} ->
          repo = get_in(auth_config(conn), [:repo, :module]) || Foresight.Repo
          rls_enabled = get_in(auth_config(conn), [:tenancy, :rls_enabled]) == true

          case fun.(tenant_id, payload, repo: repo, rls_enabled: rls_enabled) do
            {:ok, result} ->
              json(conn, 200, %{"tenant" => stringify(result)})

            {:error, {:invalid_request, message}} ->
              ErrorTranslator.send_error(
                conn,
                Error.new(:invalid_request, %{message: message})
              )

            {:error, reason} ->
              ErrorTranslator.send_error(
                conn,
                Error.new(:service_unavailable, %{message: error_message(reason)})
              )
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  defp with_authenticated(conn, fun) do
    conn = Auth.authenticate_service(conn, auth_config(conn))

    if conn.halted do
      conn
    else
      fun.(conn)
    end
  end

  defp auth_config(conn), do: Map.fetch!(conn.private, :foresight_config)

  defp parse_payload(%{} = payload), do: {:ok, payload}

  defp parse_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "expected JSON object body"})}
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp error_message(%{message: message}) when is_binary(message) and message != "", do: message
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
