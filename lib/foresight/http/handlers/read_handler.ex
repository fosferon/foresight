defmodule Foresight.HTTP.Handlers.ReadHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.HindsightWire
  alias Foresight.HTTP.RequestContext

  @integer_query_params ~w(limit offset min_count)a
  @audit_log_periods ~w(1d 7d 30d)
  @memories_timeseries_periods ~w(1h 12h 1d 7d 30d 90d)
  @memories_timeseries_time_fields ~w(created_at mentioned_at occurred_start)

  @spec list_memories(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_memories(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_memories(ctx, params) do
        json(conn, 200, HindsightWire.list_memories_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec get_memory(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def get_memory(conn, bank_id, memory_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.get_memory(ctx, memory_id) do
        json(conn, 200, HindsightWire.get_memory_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec get_memory_history(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def get_memory_history(conn, bank_id, memory_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.get_memory_history(ctx, memory_id) do
        json(conn, 200, HindsightWire.memory_history_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec list_entities(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_entities(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_entities(ctx, params) do
        json(conn, 200, HindsightWire.list_entities_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec get_entity(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def get_entity(conn, bank_id, entity_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.get_entity(ctx, entity_id) do
        json(conn, 200, HindsightWire.get_entity_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec entity_graph(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def entity_graph(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.entity_graph(ctx, params) do
        json(conn, 200, HindsightWire.entity_graph_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec regenerate_entity(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def regenerate_entity(conn, bank_id, _entity_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, _ctx} <- RequestContext.resolve(conn, bank_id) do
        json(conn, 410, %{
          "detail" => "This endpoint is deprecated. Entity observations are no longer supported."
        })
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec profile(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def profile(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.bank_profile(ctx, bank_id) do
        json(conn, 200, HindsightWire.bank_profile_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec list_tags(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_tags(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_tags(ctx, params) do
        json(conn, 200, HindsightWire.list_tags_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec list_documents(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_documents(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_documents(ctx, params) do
        json(conn, 200, HindsightWire.list_documents_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec get_document(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def get_document(conn, bank_id, document_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.get_document(ctx, document_id) do
        json(conn, 200, HindsightWire.get_document_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec list_document_chunks(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def list_document_chunks(conn, bank_id, document_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_document_chunks(ctx, document_id, params) do
        json(conn, 200, HindsightWire.list_document_chunks_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec list_audit_logs(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_audit_logs(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_audit_log_list_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_audit_logs(ctx, params) do
        json(conn, 200, result)
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec audit_log_stats(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def audit_log_stats(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_audit_log_stats_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.audit_log_stats(ctx, params) do
        json(conn, 200, result)
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec memories_timeseries(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def memories_timeseries(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <-
             parse_memories_timeseries_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <-
             Foresight.memories_timeseries(
               ctx,
               bank_id,
               params["period"],
               params["time_field"]
             ) do
        json(conn, 200, HindsightWire.memories_timeseries_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec memory_graph(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def memory_graph(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.memory_graph(ctx, params) do
        json(conn, 200, HindsightWire.memory_graph_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec get_chunk(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def get_chunk(conn, chunk_id) do
    with_authenticated(conn, fn conn ->
      conn = fetch_query_params(conn)
      bank_id = conn.query_params["bank_id"]

      with true <-
             (is_binary(bank_id) and bank_id != "") ||
               {:error, Error.new(:invalid_request, %{message: "bank_id is required"})},
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.get_chunk(ctx, chunk_id) do
        json(conn, 200, HindsightWire.get_chunk_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec list_operations(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def list_operations(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, params} <- parse_listing_params(fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.list_operations(ctx, params) do
        json(conn, 200, result)
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec get_operation(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def get_operation(conn, bank_id, operation_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.get_operation(ctx, operation_id) do
        json(conn, 200, result)
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

  defp auth_config(conn) do
    conn.private
    |> Map.fetch!(:foresight_config)
  end

  defp parse_listing_params(params) do
    Enum.reduce_while(@integer_query_params, {:ok, params}, fn key, {:ok, acc} ->
      parse_integer_param(acc, key)
    end)
  end

  defp parse_audit_log_list_params(params) do
    with {:ok, params} <- parse_listing_params(params),
         {:ok, params} <- parse_bounded_integer_param(params, "limit", 1, 500),
         {:ok, params} <- parse_nonnegative_integer_param(params, "offset"),
         {:ok, params} <- parse_datetime_param(params, "start_date"),
         {:ok, params} <- parse_datetime_param(params, "end_date") do
      {:ok, params |> Map.put_new("limit", 50) |> Map.put_new("offset", 0)}
    end
  end

  defp parse_audit_log_stats_params(params) do
    with {:ok, params} <- parse_listing_params(params),
         {:ok, params} <- parse_period_param(params) do
      {:ok, Map.put_new(params, "period", "7d")}
    end
  end

  defp parse_memories_timeseries_params(params) do
    period =
      case Map.get(params, "period", "7d") do
        value when value in @memories_timeseries_periods -> value
        _ -> "7d"
      end

    time_field =
      case Map.get(params, "time_field", "created_at") do
        value when value in @memories_timeseries_time_fields -> value
        _ -> "created_at"
      end

    {:ok, %{"period" => period, "time_field" => time_field}}
  end

  defp parse_integer_param(params, key) do
    string_key = Atom.to_string(key)

    case Map.fetch(params, string_key) do
      :error ->
        {:cont, {:ok, params}}

      {:ok, value} when is_integer(value) ->
        {:cont, {:ok, params}}

      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} ->
            {:cont, {:ok, Map.put(params, string_key, parsed)}}

          _ ->
            {:halt,
             {:error,
              Error.new(:invalid_request, %{
                message: "#{string_key} query param must be an integer"
              })}}
        end

      {:ok, _value} ->
        {:halt,
         {:error,
          Error.new(:invalid_request, %{message: "#{string_key} query param must be an integer"})}}
    end
  end

  defp parse_bounded_integer_param(params, key, min, max) do
    case parse_integer_param(params, String.to_atom(key)) do
      {:cont, {:ok, params}} ->
        case Map.fetch(params, key) do
          :error ->
            {:ok, params}

          {:ok, value} when value >= min and value <= max ->
            {:ok, params}

          {:ok, _value} ->
            {:error,
             Error.new(:invalid_request, %{
               message: "#{key} query param must be between #{min} and #{max}"
             })}
        end

      {:halt, {:error, %Error{} = error}} ->
        {:error, error}
    end
  end

  defp parse_nonnegative_integer_param(params, key) do
    case parse_integer_param(params, String.to_atom(key)) do
      {:cont, {:ok, params}} ->
        case Map.fetch(params, key) do
          :error ->
            {:ok, params}

          {:ok, value} when value >= 0 ->
            {:ok, params}

          {:ok, _value} ->
            {:error,
             Error.new(:invalid_request, %{
               message: "#{key} query param must be greater than or equal to 0"
             })}
        end

      {:halt, {:error, %Error{} = error}} ->
        {:error, error}
    end
  end

  defp parse_datetime_param(params, key) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, params}

      {:ok, %DateTime{}} ->
        {:ok, params}

      {:ok, value} when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            {:ok, Map.put(params, key, datetime)}

          _ ->
            {:error,
             Error.new(:invalid_request, %{
               message: "#{key} query param must be an ISO-8601 datetime"
             })}
        end

      {:ok, _value} ->
        {:error,
         Error.new(:invalid_request, %{message: "#{key} query param must be an ISO-8601 datetime"})}
    end
  end

  defp parse_period_param(params) do
    case Map.get(params, "period") do
      nil ->
        {:ok, params}

      period when period in @audit_log_periods ->
        {:ok, params}

      _other ->
        {:error,
         Error.new(:invalid_request, %{message: "period query param must be one of: 1d, 7d, 30d"})}
    end
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
