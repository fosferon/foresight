defmodule Foresight.HTTP.Handlers.MentalModelHandler do
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
             HindsightWire.normalize_mental_model_query(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, models} <-
             Foresight.list_mental_models(ctx, bank_id, params, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.mental_model_list_response(models, params["detail"]))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec show(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def show(conn, bank_id, mental_model_id) do
    with_authenticated(conn, fn conn ->
      params = HindsightWire.normalize_mental_model_detail(fetch_query_params(conn).query_params)

      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, model} <-
             Foresight.get_mental_model(
               ctx,
               bank_id,
               mental_model_id,
               params,
               config: auth_config(conn)
             ) do
        json(conn, 200, HindsightWire.mental_model_response(model, params["detail"]))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec history(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def history(conn, bank_id, mental_model_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, history} <-
             Foresight.get_mental_model_history(
               ctx,
               bank_id,
               mental_model_id,
               config: auth_config(conn)
             ) do
        json(conn, 200, HindsightWire.mental_model_history_response(history))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec create(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def create(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, attrs} <- HindsightWire.normalize_create_mental_model_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <-
             Foresight.create_mental_model(ctx, bank_id, attrs, config: auth_config(conn)) do
        json(conn, 200, HindsightWire.create_mental_model_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec refresh(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def refresh(conn, bank_id, mental_model_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <-
             Foresight.refresh_mental_model(
               ctx,
               bank_id,
               mental_model_id,
               config: auth_config(conn)
             ) do
        json(conn, 200, HindsightWire.refresh_mental_model_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec patch(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def patch(conn, bank_id, mental_model_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, attrs} <- HindsightWire.normalize_update_mental_model_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, model} <-
             Foresight.update_mental_model(
               ctx,
               bank_id,
               mental_model_id,
               attrs,
               config: auth_config(conn)
             ) do
        json(conn, 200, HindsightWire.mental_model_response(model, "full"))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, bank_id, mental_model_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, _result} <-
             Foresight.delete_mental_model(
               ctx,
               bank_id,
               mental_model_id,
               config: auth_config(conn)
             ) do
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
