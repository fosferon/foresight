defmodule Foresight.HTTP.Handlers.ConfigHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.Config.Guard
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.HindsightWire
  alias Foresight.HTTP.RequestContext

  @spec show(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def show(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, response} <- Foresight.get_bank_config(ctx, bank_id, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.bank_config_response(response))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec patch(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def patch(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, updates} <- parse_updates(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, response} <-
             Foresight.update_bank_config(ctx, bank_id, updates, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.bank_config_response(response))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, response} <- Foresight.reset_bank_config(ctx, bank_id, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.bank_config_response(response))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  defp with_authenticated(conn, fun) do
    conn = Auth.authenticate(conn, auth_config(conn))

    if conn.halted do
      conn
    else
      fun.(conn)
    end
  end

  defp auth_config(conn), do: Map.fetch!(conn.private, :foresight_config)

  defp parse_updates(%{"updates" => updates}) when is_map(updates) do
    case Guard.validate_updates(updates) do
      :ok -> {:ok, updates}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp parse_updates(_body) do
    {:error,
     Error.new(:invalid_request, %{message: "config updates must be an object under updates"})}
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
