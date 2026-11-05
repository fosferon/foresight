defmodule Foresight.HTTP.Handlers.DirectiveHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.HindsightWire
  alias Foresight.HTTP.RequestContext

  @spec index(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def index(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <-
             HindsightWire.normalize_directive_query(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, directives} <-
             Foresight.list_directives(ctx, bank_id, params, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.directive_list_response(directives))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec show(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def show(conn, bank_id, directive_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, directive} <-
             Foresight.get_directive(ctx, bank_id, directive_id, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.directive_response(directive))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec create(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, attrs} <- HindsightWire.normalize_create_directive_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, directive} <-
             Foresight.create_directive(ctx, bank_id, attrs, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.directive_response(directive))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec patch(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def patch(conn, bank_id, directive_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, attrs} <- HindsightWire.normalize_update_directive_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, directive} <-
             Foresight.update_directive(
               ctx,
               bank_id,
               directive_id,
               attrs,
               config: auth_config(conn)
             ) do
        json(conn, 200, HindsightWire.directive_response(directive))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, bank_id, directive_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, _result} <-
             Foresight.delete_directive(ctx, bank_id, directive_id, config: auth_config(conn)) do
        json(conn, 200, %{"status" => "deleted"})
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
