defmodule Foresight.HTTP.Handlers.MemoryHandler do
  @moduledoc false

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.HindsightWire
  alias Foresight.HTTP.RequestContext

  import Plug.Conn

  @spec retain(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retain(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, payload} <- HindsightWire.normalize_retain_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.retain(ctx, payload) do
        json(conn, 200, HindsightWire.retain_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec retain_files(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def retain_files(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      if file_ingestion_enabled?(conn) do
        with {:ok, payload} <- HindsightWire.normalize_file_retain_payload(conn.body_params),
             {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
             {:ok, result} <- Foresight.retain_files(ctx, payload) do
          json(conn, 200, HindsightWire.file_retain_response(result))
        else
          error -> ErrorTranslator.send_error(conn, error)
        end
      else
        ErrorTranslator.send_error(
          conn,
          Error.new(:not_found, %{message: "file ingestion is disabled"})
        )
      end
    end)
  end

  @spec recall(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def recall(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, payload} <- HindsightWire.normalize_recall_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.recall(ctx, payload) do
        json(conn, 200, HindsightWire.recall_response(result, payload))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec reflect(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def reflect(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, payload} <- HindsightWire.normalize_reflect_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.reflect(ctx, payload) do
        json(conn, 200, HindsightWire.reflect_response(result, payload))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec consolidate(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def consolidate(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, payload} <- HindsightWire.normalize_consolidate_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.consolidate(ctx, payload) do
        json(conn, 200, HindsightWire.consolidate_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec recover_consolidation(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def recover_consolidation(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.recover_consolidation(ctx, bank_id) do
        json(conn, 200, HindsightWire.recover_consolidation_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec patch_document(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def patch_document(conn, bank_id, document_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, payload} <- HindsightWire.normalize_update_document_payload(conn.body_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.update_document(ctx, bank_id, document_id, payload) do
        json(conn, 200, HindsightWire.update_document_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete_document(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def delete_document(conn, bank_id, document_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.delete_document(ctx, bank_id, document_id) do
        json(conn, 200, HindsightWire.delete_document_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete_memory(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def delete_memory(conn, bank_id, memory_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.delete_memory(ctx, bank_id, memory_id) do
        json(conn, 200, HindsightWire.delete_memory_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec reprocess_document(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def reprocess_document(conn, bank_id, document_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.reprocess_document(ctx, bank_id, document_id) do
        json(conn, 200, HindsightWire.reprocess_document_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec clear_observations(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def clear_observations(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.clear_observations(ctx, bank_id) do
        json(conn, 200, HindsightWire.clear_observations_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec cancel_operation(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def cancel_operation(conn, bank_id, operation_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.cancel_operation(ctx, operation_id) do
        json(conn, 200, HindsightWire.cancel_operation_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec retry_operation(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def retry_operation(conn, bank_id, operation_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.retry_operation(ctx, operation_id) do
        json(conn, 200, HindsightWire.retry_operation_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec clear_memory_observations(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def clear_memory_observations(conn, bank_id, memory_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.clear_memory_observations(ctx, bank_id, memory_id) do
        json(conn, 200, HindsightWire.clear_memory_observations_response(result))
      else
        error -> ErrorTranslator.send_error(conn, error)
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

  defp auth_config(conn) do
    conn.private
    |> Map.fetch!(:foresight_config)
  end

  defp file_ingestion_enabled?(conn) do
    conn.private
    |> Map.fetch!(:foresight_config)
    |> get_in([:file_ingestion, :enabled]) == true
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
