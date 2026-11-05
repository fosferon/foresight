defmodule Foresight.HTTP.Handlers.WebhookHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.HindsightWire
  alias Foresight.HTTP.RequestContext

  @spec create(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, attrs} <- HindsightWire.normalize_create_webhook_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, webhook} <-
             Foresight.create_webhook(ctx, bank_id, attrs, config: auth_config(conn)) do
        json(conn, 201, HindsightWire.webhook_response(webhook))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec index(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def index(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, webhooks} <- Foresight.list_webhooks(ctx, bank_id, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.webhook_list_response(webhooks))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec patch(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def patch(conn, bank_id, webhook_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, attrs} <- HindsightWire.normalize_update_webhook_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, webhook} <-
             Foresight.update_webhook(ctx, bank_id, webhook_id, attrs, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.webhook_response(webhook))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, bank_id, webhook_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <-
             Foresight.delete_webhook(ctx, bank_id, webhook_id, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.webhook_delete_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec deliveries(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def deliveries(conn, bank_id, webhook_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <-
             HindsightWire.normalize_webhook_delivery_params(
               fetch_query_params(conn).query_params
             ),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, response} <-
             Foresight.list_webhook_deliveries(
               ctx,
               bank_id,
               webhook_id,
               params,
               config: auth_config(conn)
             ) do
        json(conn, 200, HindsightWire.webhook_delivery_list_response(response))
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

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
