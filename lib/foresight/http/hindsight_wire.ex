defmodule Foresight.HTTP.HindsightWire do
  @moduledoc false

  alias Foresight.Config.Fields

  alias Foresight.Error

  # Hindsight's recall has no pagination; these stay rejected. `min_score` is an
  # additive Foresight extension (a cutoff on the returned `score`), as is `score`
  # on each result.
  @invented_recall_fields ~w(after before limit offset)

  def normalize_retain_payload(%{"items" => items} = payload) when is_list(items) do
    normalized_items =
      Enum.map(items, fn item ->
        timestamp = item["timestamp"]

        item
        |> Map.put_new("context", "")
        |> maybe_put("mentioned_at", normalize_timestamp(timestamp))
        |> maybe_put("occurred_at", normalize_timestamp(timestamp))
      end)

    {:ok, Map.put(payload, "items", normalized_items)}
  end

  def normalize_retain_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "retain payload must include an items list"})}
  end

  def normalize_file_retain_payload(%{"files" => files} = payload) when is_list(files) do
    with {:ok, request} <- decode_file_retain_request(Map.get(payload, "request", %{})),
         {:ok, normalized_files} <- normalize_file_inputs(files),
         :ok <- validate_files_metadata_count(request, normalized_files),
         {:ok, files_with_metadata} <- apply_files_metadata(normalized_files, request) do
      request =
        request
        |> Map.delete("files_metadata")
        |> Map.put("async", true)

      {:ok, %{"files" => files_with_metadata, "request" => request}}
    end
  end

  def normalize_file_retain_payload(%{"files" => file} = payload) do
    normalize_file_retain_payload(Map.put(payload, "files", [file]))
  end

  def normalize_file_retain_payload(_payload) do
    {:error,
     Error.new(:invalid_request, %{message: "file retain payload must include a files list"})}
  end

  def normalize_recall_payload(%{"query" => query} = payload) when is_binary(query) do
    case Enum.find(@invented_recall_fields, &Map.has_key?(payload, &1)) do
      nil ->
        {:ok, payload}

      key ->
        {:error,
         Error.new(:invalid_request, %{
           message: "#{key} is not part of hindsight's recall contract"
         })}
    end
  end

  def normalize_recall_payload(_payload) do
    {:error,
     Error.new(:invalid_request, %{message: "recall payload must include a query string"})}
  end

  def normalize_reflect_payload(%{"query" => query} = payload) when is_binary(query),
    do: {:ok, payload}

  def normalize_reflect_payload(_payload) do
    {:error,
     Error.new(:invalid_request, %{message: "reflect payload must include a query string"})}
  end

  def normalize_consolidate_payload(payload) when is_map(payload) do
    normalized =
      payload
      |> normalize_observation_scopes()
      |> Map.put_new("async", true)

    {:ok, normalized}
  end

  def normalize_consolidate_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "consolidate payload must be an object"})}
  end

  def normalize_create_webhook_payload(payload) when is_map(payload) do
    with {:ok, url} <- fetch_required_string(payload, "url"),
         {:ok, secret} <- normalize_optional_string(payload, "secret"),
         {:ok, event_types} <- normalize_webhook_event_types(Map.get(payload, "event_types")),
         {:ok, enabled} <- normalize_optional_boolean(payload, "enabled", true),
         {:ok, http_config} <- normalize_webhook_http_config(Map.get(payload, "http_config")) do
      {:ok,
       %{
         "url" => url,
         "secret" => secret,
         "event_types" => event_types,
         "enabled" => enabled,
         "http_config" => http_config
       }}
    end
  end

  def normalize_create_webhook_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "webhook payload must be an object"})}
  end

  def normalize_update_webhook_payload(payload) when is_map(payload) do
    with {:ok, attrs} <-
           payload
           |> Enum.reduce_while({:ok, %{}}, fn
             {"url", _value}, {:ok, acc} ->
               case fetch_required_string(payload, "url") do
                 {:ok, url} -> {:cont, {:ok, Map.put(acc, "url", url)}}
                 {:error, %Error{} = error} -> {:halt, {:error, error}}
               end

             {"secret", _value}, {:ok, acc} ->
               case normalize_optional_string(payload, "secret") do
                 {:ok, secret} -> {:cont, {:ok, Map.put(acc, "secret", secret)}}
                 {:error, %Error{} = error} -> {:halt, {:error, error}}
               end

             {"event_types", value}, {:ok, acc} ->
               case normalize_webhook_event_types(value) do
                 {:ok, event_types} -> {:cont, {:ok, Map.put(acc, "event_types", event_types)}}
                 {:error, %Error{} = error} -> {:halt, {:error, error}}
               end

             {"enabled", _value}, {:ok, acc} ->
               case normalize_optional_boolean(payload, "enabled", nil) do
                 {:ok, enabled} -> {:cont, {:ok, Map.put(acc, "enabled", enabled)}}
                 {:error, %Error{} = error} -> {:halt, {:error, error}}
               end

             {"http_config", value}, {:ok, acc} ->
               case normalize_webhook_http_config(value, allow_nil: true) do
                 {:ok, http_config} -> {:cont, {:ok, Map.put(acc, "http_config", http_config)}}
                 {:error, %Error{} = error} -> {:halt, {:error, error}}
               end

             {_key, _value}, {:ok, acc} ->
               {:cont, {:ok, acc}}
           end) do
      if map_size(attrs) == 0 do
        {:error, Error.new(:invalid_request, %{message: "No fields provided to update"})}
      else
        {:ok, attrs}
      end
    end
  end

  def normalize_update_webhook_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "webhook payload must be an object"})}
  end

  def normalize_webhook_delivery_params(params) when is_map(params) do
    with {:ok, limit} <- normalize_limit(Map.get(params, "limit")),
         {:ok, cursor} <- normalize_cursor(Map.get(params, "cursor")) do
      {:ok, %{"limit" => limit, "cursor" => cursor}}
    end
  end

  def normalize_webhook_delivery_params(_params) do
    {:error, Error.new(:invalid_request, %{message: "delivery query params must be an object"})}
  end

  def normalize_directive_query(params) when is_map(params) do
    with {:ok, limit} <- normalize_limit(Map.get(params, "limit")),
         {:ok, offset} <- normalize_offset(Map.get(params, "offset")),
         {:ok, active_only} <- normalize_boolean_param(Map.get(params, "active_only", true), true) do
      {:ok,
       %{
         "tags" => normalize_tags_param(Map.get(params, "tags")),
         "tags_match" => Map.get(params, "tags_match", "any"),
         "active_only" => active_only,
         "limit" => limit,
         "offset" => offset
       }}
    end
  end

  def normalize_directive_query(_params) do
    {:error, Error.new(:invalid_request, %{message: "directive query params must be an object"})}
  end

  def normalize_create_directive_payload(payload) when is_map(payload) do
    with {:ok, name} <- fetch_required_string(payload, "name"),
         {:ok, content} <- fetch_required_string(payload, "content"),
         {:ok, priority} <- normalize_optional_integer(payload, "priority", 0),
         {:ok, is_active} <- normalize_optional_boolean(payload, "is_active", true),
         {:ok, tags} <- normalize_tags_field(Map.get(payload, "tags", [])) do
      {:ok,
       %{
         "name" => name,
         "content" => content,
         "priority" => priority,
         "is_active" => is_active,
         "tags" => tags
       }}
    end
  end

  def normalize_create_directive_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "directive payload must be an object"})}
  end

  def normalize_update_directive_payload(payload) when is_map(payload) do
    with {:ok, attrs} <-
           collect_patch_attrs(
             payload,
             ["name", "content"],
             ["priority"],
             ["is_active"],
             ["tags"],
             []
           ) do
      if map_size(attrs) == 0 do
        {:error, Error.new(:invalid_request, %{message: "No fields provided to update"})}
      else
        {:ok, attrs}
      end
    end
  end

  def normalize_update_directive_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "directive payload must be an object"})}
  end

  def normalize_mental_model_query(params) when is_map(params) do
    with {:ok, limit} <- normalize_limit(Map.get(params, "limit")),
         {:ok, offset} <- normalize_offset(Map.get(params, "offset")) do
      {:ok,
       %{
         "tags" => normalize_tags_param(Map.get(params, "tags")),
         "tags_match" => Map.get(params, "tags_match", "any"),
         "detail" => normalize_detail(Map.get(params, "detail", "full")),
         "limit" => limit,
         "offset" => offset
       }}
    end
  end

  def normalize_mental_model_query(_params) do
    {:error,
     Error.new(:invalid_request, %{message: "mental model query params must be an object"})}
  end

  def normalize_mental_model_detail(params) when is_map(params) do
    %{"detail" => normalize_detail(Map.get(params, "detail", "full"))}
  end

  def normalize_create_mental_model_payload(payload) when is_map(payload) do
    with {:ok, id} <- normalize_optional_string(payload, "id"),
         {:ok, name} <- fetch_required_string(payload, "name"),
         {:ok, source_query} <- fetch_required_string(payload, "source_query"),
         {:ok, tags} <- normalize_tags_field(Map.get(payload, "tags", [])),
         {:ok, max_tokens} <- normalize_optional_integer(payload, "max_tokens", 2048),
         {:ok, trigger} <- normalize_optional_map(payload, "trigger", %{}) do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "source_query" => source_query,
         "tags" => tags,
         "max_tokens" => max_tokens,
         "trigger" => trigger
       }}
    end
  end

  def normalize_create_mental_model_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "mental model payload must be an object"})}
  end

  def normalize_update_mental_model_payload(payload) when is_map(payload) do
    with {:ok, attrs} <-
           collect_patch_attrs(payload, ["name", "source_query"], ["max_tokens"], [], ["tags"], [
             "trigger"
           ]) do
      if map_size(attrs) == 0 do
        {:error, Error.new(:invalid_request, %{message: "No fields provided to update"})}
      else
        {:ok, attrs}
      end
    end
  end

  def normalize_update_mental_model_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "mental model payload must be an object"})}
  end

  def create_mental_model_response(result) do
    %{
      "mental_model_id" => result["mental_model_id"],
      "operation_id" => result["operation_id"]
    }
  end

  def mental_model_history_response(history) when is_list(history), do: history

  def refresh_mental_model_response(result) do
    %{
      "operation_id" => result["operation_id"],
      "status" => Map.get(result, "status", "queued")
    }
  end

  def retain_response(result) do
    async? = Map.get(result, "async", false)

    base = %{
      "success" => Map.get(result, "success", true),
      "bank_id" => result["bank_id"],
      "items_count" => Map.get(result, "items_count", 0),
      "async" => Map.get(result, "async", false),
      "operation_id" => result["operation_id"]
    }

    if(async?,
      do:
        base
        |> Map.put("operation_ids", result["operation_ids"])
        |> Map.put("usage", result["usage"]),
      else: maybe_put_map(base, "usage", result["usage"])
    )
    |> maybe_put_map("extraction", result["extraction"])
    |> maybe_put_map("trace", result["trace"])
    |> compact_map_preserve_nil(["operation_ids", "usage"])
  end

  def file_retain_response(result) do
    operation_ids =
      cond do
        is_list(result["operation_ids"]) -> result["operation_ids"]
        is_binary(result["operation_id"]) -> [result["operation_id"]]
        true -> []
      end

    %{"operation_ids" => operation_ids}
  end

  def consolidate_response(result) do
    %{
      "operation_id" => result["operation_id"],
      "deduplicated" => Map.get(result, "deduplicated", false)
    }
  end

  def recall_response(result, payload) do
    base =
      %{"results" => Enum.map(Map.get(result, "results", []), &recall_result/1)}
      |> maybe_put_map("usage", result["usage"])
      |> maybe_put_map("stats", result["stats"])

    base =
      maybe_put_map(
        base,
        "trace",
        if(Map.get(payload, "trace", false), do: result["trace"], else: nil)
      )

    base =
      maybe_put_included_map(
        base,
        "entities",
        recall_entities(result, payload),
        include_entities?(payload)
      )

    base =
      maybe_put_included_map(
        base,
        "chunks",
        recall_chunks(result, payload),
        include_chunks?(payload)
      )

    maybe_put_included_map(
      base,
      "source_facts",
      recall_source_facts(result, payload),
      include_source_facts?(payload)
    )
  end

  def reflect_response(result, payload) do
    base = %{
      "text" => result["text"],
      "memory_ids" => Map.get(result, "memory_ids"),
      "mental_model_ids" => Map.get(result, "mental_model_ids"),
      "observation_ids" => Map.get(result, "observation_ids"),
      "based_on" =>
        if(include_facts?(payload), do: Map.get(result, "based_on", empty_based_on()), else: nil),
      "usage" => Map.get(result, "usage"),
      "trace" =>
        if(include_tool_calls?(payload),
          do: shape_reflect_trace(Map.get(result, "trace", empty_trace()), payload),
          else: nil
        )
    }

    if(Map.has_key?(payload, "response_schema"),
      do: Map.put(base, "structured_output", Map.get(result, "structured_output")),
      else: base
    )
    |> compact_map_preserve_nil(["structured_output"])
  end

  def bank_list_response(banks), do: %{"banks" => Enum.map(banks, &bank_list_item/1)}

  def bank_profile_response(profile) do
    mission = profile["mission"] || profile["background"] || ""

    %{
      "bank_id" => profile["bank_id"] || profile["id"],
      "name" => profile["name"] || profile["bank_id"] || profile["id"],
      "disposition" => normalize_disposition(profile["disposition"]),
      "mission" => mission,
      "background" => mission
    }
  end

  def background_response(result) do
    mission = result["mission"] || result["background"] || ""

    %{
      "mission" => mission,
      "background" => mission,
      "disposition" => maybe_background_disposition(result)
    }
    |> compact_map_preserve_nil(["disposition"])
  end

  def bank_stats_response(stats) do
    observation_count =
      stats
      |> Map.get("nodes_by_fact_type", %{})
      |> Map.get("observation", 0)

    %{
      "bank_id" => stats["bank_id"] || stats["id"],
      "total_nodes" => Map.get(stats, "total_nodes", 0),
      "total_links" => Map.get(stats, "total_links", 0),
      "total_documents" => Map.get(stats, "total_documents", 0),
      "nodes_by_fact_type" => Map.get(stats, "nodes_by_fact_type", %{}),
      "links_by_link_type" => Map.get(stats, "links_by_link_type", %{}),
      "links_by_fact_type" => Map.get(stats, "links_by_fact_type", %{}),
      "links_breakdown" => Map.get(stats, "links_breakdown", %{}),
      "pending_operations" => Map.get(stats, "pending_operations", 0),
      "failed_operations" => Map.get(stats, "failed_operations", 0),
      "operations_by_status" => Map.get(stats, "operations_by_status", %{}),
      "last_consolidated_at" => Map.get(stats, "last_consolidated_at"),
      "pending_consolidation" => Map.get(stats, "pending_consolidation", 0),
      "failed_consolidation" => Map.get(stats, "failed_consolidation", 0),
      "total_observations" => Map.get(stats, "total_observations", observation_count)
    }
    |> compact_map_preserve_nil(["last_consolidated_at"])
  end

  def memories_timeseries_response(result) do
    %{
      "bank_id" => result["bank_id"] || result["id"],
      "period" => Map.get(result, "period", "7d"),
      "trunc" => Map.get(result, "trunc", "day"),
      "time_field" => Map.get(result, "time_field", "created_at"),
      "buckets" =>
        Enum.map(Map.get(result, "buckets", []), fn bucket ->
          %{
            "time" => bucket["time"],
            "world" => Map.get(bucket, "world", 0),
            "experience" => Map.get(bucket, "experience", 0),
            "observation" => Map.get(bucket, "observation", 0)
          }
        end)
    }
  end

  def delete_response(result, bank_id) do
    %{
      "success" => Map.get(result, "deleted", true),
      "message" =>
        Map.get(
          result,
          "message",
          "Bank '#{bank_id}' and all associated data deleted successfully"
        ),
      "deleted_count" => result["deleted_count"]
    }
    |> compact_map()
  end

  def bank_config_response(
        %{"bank_id" => _bank_id, "config" => _config, "overrides" => _overrides} = response
      ) do
    %{
      "bank_id" => response["bank_id"],
      "config" => Fields.redact_credentials(Map.get(response, "config", %{})),
      "overrides" => Fields.redact_credentials(Map.get(response, "overrides", %{}))
    }
  end

  def clear_memories_response(result) do
    %{
      "success" => Map.get(result, "success", Map.get(result, "deleted", true)),
      "message" => Map.get(result, "message"),
      "deleted_count" => Map.get(result, "deleted_count")
    }
    |> compact_map_preserve_nil(["message", "deleted_count"])
  end

  def webhook_response(result) do
    %{
      "id" => result["id"],
      "bank_id" => result["bank_id"],
      "url" => result["url"],
      "secret" => nil,
      "event_types" => Map.get(result, "event_types", ["consolidation.completed"]),
      "enabled" => Map.get(result, "enabled", true),
      "http_config" => response_http_config(result["http_config"]),
      "created_at" => result["created_at"],
      "updated_at" => result["updated_at"]
    }
    |> compact_map_preserve_nil(["bank_id", "created_at", "updated_at", "secret"])
  end

  def webhook_list_response(items) when is_list(items) do
    %{"items" => Enum.map(items, &webhook_response/1)}
  end

  def webhook_delete_response(result) do
    %{
      "success" => Map.get(result, "success", Map.get(result, "deleted", true)),
      "message" => Map.get(result, "message"),
      "deleted_count" => Map.get(result, "deleted_count")
    }
  end

  def webhook_delivery_list_response(result) do
    %{
      "items" => Enum.map(Map.get(result, "items", []), &webhook_delivery_item/1),
      "next_cursor" => result["next_cursor"]
    }
    |> compact_map_preserve_nil(["next_cursor"])
  end

  def list_memories_response(result) do
    %{
      "items" => Enum.map(Map.get(result, "items", []), &list_memory_item/1),
      "total" => Map.get(result, "total", 0),
      "limit" => Map.get(result, "limit", 100),
      "offset" => Map.get(result, "offset", 0)
    }
  end

  def get_memory_response(result) do
    %{
      "id" => result["id"],
      "text" => result["text"] || result["content"],
      "context" => result["context"],
      "date" => result["date"] || result["mentioned_at"],
      "type" => result["type"],
      "mentioned_at" => result["mentioned_at"] || result["date"],
      "occurred_start" => result["occurred_start"],
      "occurred_end" => result["occurred_end"],
      "entities" => result["entities"],
      "document_id" => result["document_id"],
      "chunk_id" => result["chunk_id"],
      "tags" => Map.get(result, "tags", []),
      "observation_scopes" => result["observation_scopes"]
    }
    |> compact_map_preserve_nil([
      "context",
      "occurred_start",
      "occurred_end",
      "entities",
      "document_id",
      "chunk_id",
      "observation_scopes"
    ])
  end

  def memory_history_response(history) when is_list(history), do: history

  def list_tags_response(result) do
    %{
      "items" => Enum.map(Map.get(result, "items", []), &tag_item/1),
      "total" => Map.get(result, "total", 0),
      "limit" => Map.get(result, "limit", 100),
      "offset" => Map.get(result, "offset", 0)
    }
  end

  def directive_response(result) do
    %{
      "id" => result["id"],
      "bank_id" => result["bank_id"],
      "name" => result["name"],
      "content" => result["content"],
      "priority" => Map.get(result, "priority", 0),
      "is_active" => Map.get(result, "is_active", true),
      "tags" => Map.get(result, "tags", []),
      "created_at" => result["created_at"],
      "updated_at" => result["updated_at"]
    }
    |> compact_map_preserve_nil(["created_at", "updated_at"])
  end

  def directive_list_response(result) do
    %{"items" => Enum.map(Map.get(result, "items", []), &directive_response/1)}
  end

  def mental_model_list_response(result, detail) do
    %{"items" => Enum.map(Map.get(result, "items", []), &mental_model_response(&1, detail))}
  end

  def mental_model_response(result, detail \\ "full") do
    base = %{
      "id" => result["id"],
      "bank_id" => result["bank_id"],
      "name" => result["name"],
      "source_query" => result["source_query"],
      "tags" => Map.get(result, "tags", []),
      "max_tokens" => result["max_tokens"],
      "trigger" => result["trigger"],
      "last_refreshed_at" => result["last_refreshed_at"],
      "created_at" => result["created_at"]
    }

    base =
      case detail do
        "metadata" ->
          base

        "content" ->
          Map.put(base, "content", result["content"])

        _ ->
          base
          |> Map.put("content", result["content"])
          |> Map.put("reflect_response", result["reflect_response"])
          |> Map.put("is_stale", result["is_stale"])
          |> maybe_put_map("staleness_reason", result["staleness_reason"])
      end

    base
    |> compact_map_preserve_nil([
      "source_query",
      "max_tokens",
      "trigger",
      "last_refreshed_at",
      "created_at",
      "content",
      "reflect_response",
      "is_stale"
    ])
  end

  def list_entities_response(result), do: result
  def entity_graph_response(result), do: result

  def get_entity_response(result) do
    %{
      "id" => result["id"],
      "canonical_name" => result["canonical_name"],
      "mention_count" => result["mention_count"],
      "first_seen" => result["first_seen"],
      "last_seen" => result["last_seen"],
      "metadata" => result["metadata"],
      "observations" => Map.get(result, "observations", [])
    }
    |> compact_map_preserve_nil(["first_seen", "last_seen", "metadata"])
  end

  def list_documents_response(result) do
    %{
      "items" => Enum.map(Map.get(result, "items", []), &document_item/1),
      "total" => Map.get(result, "total", 0),
      "limit" => Map.get(result, "limit", 100),
      "offset" => Map.get(result, "offset", 0)
    }
  end

  def get_document_response(result) do
    %{
      "id" => result["id"],
      "bank_id" => result["bank_id"],
      "original_text" => result["original_text"],
      "content_hash" => result["content_hash"],
      "created_at" => result["created_at"],
      "updated_at" => result["updated_at"],
      "memory_unit_count" => result["memory_unit_count"],
      "nodes_by_fact_type" => result["nodes_by_fact_type"],
      "tags" => Map.get(result, "tags", []),
      "document_metadata" => result["document_metadata"],
      "retain_params" => result["retain_params"]
    }
    |> compact_map_preserve_nil([
      "content_hash",
      "nodes_by_fact_type",
      "document_metadata",
      "retain_params"
    ])
  end

  def list_document_chunks_response(result) do
    %{
      "items" => Enum.map(Map.get(result, "items", []), &get_chunk_response/1),
      "total" => Map.get(result, "total", 0),
      "limit" => Map.get(result, "limit", 100),
      "offset" => Map.get(result, "offset", 0)
    }
  end

  def update_document_response(_result), do: %{"success" => true}

  def delete_document_response(result) do
    %{
      "success" => Map.get(result, "success", true),
      "message" => result["message"],
      "document_id" => result["document_id"],
      "memory_units_deleted" => Map.get(result, "memory_units_deleted", 0)
    }
    |> compact_map_preserve_nil(["message", "document_id"])
  end

  # Foresight extension (Hindsight has no single-memory delete), shaped like the
  # document delete response so clients can treat the two alike.
  def delete_memory_response(result) do
    %{
      "success" => Map.get(result, "success", true),
      "memory_id" => result["memory_id"],
      "memory_units_deleted" => Map.get(result, "memory_units_deleted", 1),
      "observations_deleted" => Map.get(result, "observations_deleted", 0)
    }
  end

  def reprocess_document_response(result) do
    %{
      "success" => Map.get(result, "success", true),
      "operation_id" => result["operation_id"],
      "items_count" => Map.get(result, "items_count", 0)
    }
  end

  def clear_observations_response(result) do
    %{
      "success" => Map.get(result, "success", true),
      "deleted_count" => Map.get(result, "deleted_count", 0),
      "message" => result["message"]
    }
    |> compact_map()
  end

  def cancel_operation_response(result) do
    %{
      "success" => Map.get(result, "success", true),
      "message" => result["message"],
      "operation_id" => result["operation_id"]
    }
    |> compact_map()
  end

  def retry_operation_response(result) do
    %{
      "success" => Map.get(result, "success", true),
      "message" => result["message"],
      "operation_id" => result["operation_id"]
    }
    |> compact_map()
  end

  def recover_consolidation_response(result) do
    %{
      "retried_count" => Map.get(result, "retried_count", 0)
    }
  end

  def clear_memory_observations_response(result) do
    %{"deleted_count" => Map.get(result, "deleted_count", 0)}
  end

  def memory_graph_response(result), do: result

  def get_chunk_response(result) do
    %{
      "chunk_id" => result["chunk_id"],
      "document_id" => result["document_id"],
      "bank_id" => result["bank_id"],
      "chunk_index" => result["chunk_index"],
      "chunk_text" => result["chunk_text"],
      "created_at" => result["created_at"]
    }
  end

  def normalize_update_document_payload(payload) when is_map(payload) do
    tags = Map.get(payload, "tags")

    cond do
      is_list(tags) ->
        {:ok, %{"tags" => tags}}

      map_size(payload) == 0 ->
        {:error,
         Error.new(:invalid_request, %{message: "At least one field (tags) must be provided"})}

      true ->
        {:error, Error.new(:invalid_request, %{message: "tags must be a list of strings"})}
    end
  end

  def normalize_update_document_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "document payload must be an object"})}
  end

  defp list_memory_item(item) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "context" => item["context"],
      "date" => item["date"] || item["mentioned_at"],
      "type" => item["type"],
      "entities" => format_entities(item["entities"] || [])
    }
    |> compact_map()
  end

  defp document_item(item) do
    %{
      "id" => item["id"],
      "bank_id" => item["bank_id"],
      "content_hash" => item["content_hash"],
      "created_at" => item["created_at"],
      "updated_at" => item["updated_at"],
      "text_length" => item["text_length"],
      "memory_unit_count" => Map.get(item, "memory_unit_count", 0),
      "tags" => Map.get(item, "tags", []),
      "document_metadata" => item["document_metadata"],
      "retain_params" => item["retain_params"]
    }
    |> compact_map()
  end

  defp webhook_delivery_item(item) do
    %{
      "id" => item["id"],
      "webhook_id" => item["webhook_id"],
      "url" => item["url"],
      "event_type" => item["event_type"],
      "status" => item["status"],
      "attempts" => Map.get(item, "attempts", 0),
      "next_retry_at" => item["next_retry_at"],
      "last_error" => item["last_error"],
      "last_response_status" => item["last_response_status"],
      "last_response_body" => item["last_response_body"],
      "last_attempt_at" => item["last_attempt_at"],
      "created_at" => item["created_at"],
      "updated_at" => item["updated_at"]
    }
    |> compact_map_preserve_nil([
      "webhook_id",
      "next_retry_at",
      "last_error",
      "last_response_status",
      "last_response_body",
      "last_attempt_at",
      "created_at",
      "updated_at"
    ])
  end

  defp tag_item(item) do
    %{
      "tag" => item["tag"],
      "count" => item["count"]
    }
  end

  defp bank_list_item(bank) do
    mission = bank["mission"] || bank["background"]

    %{
      "bank_id" => bank["bank_id"] || bank["id"],
      "name" => bank["name"],
      "disposition" => normalize_disposition(bank["disposition"]),
      "mission" => mission,
      "created_at" => bank["created_at"],
      "updated_at" => bank["updated_at"],
      "fact_count" => bank["fact_count"],
      "last_document_at" => bank["last_document_at"]
    }
    |> compact_map()
  end

  defp recall_result(item) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "type" => item["type"],
      "score" => item["score"],
      "entities" => item["entities"],
      "context" => item["context"],
      "occurred_start" => item["occurred_start"],
      "occurred_end" => item["occurred_end"],
      "mentioned_at" => item["mentioned_at"],
      "document_id" => item["document_id"],
      "metadata" => item["metadata"],
      "chunk_id" => item["chunk_id"],
      "tags" => item["tags"],
      "source_fact_ids" => item["source_fact_ids"]
    }
    |> compact_map_preserve_nil([
      "entities",
      "context",
      "occurred_start",
      "occurred_end",
      "document_id",
      "chunk_id",
      "source_fact_ids"
    ])
  end

  defp recall_entities(result, payload) do
    if include_entities?(payload), do: Map.get(result, "entities"), else: nil
  end

  defp recall_chunks(result, payload) do
    if include_chunks?(payload), do: Map.get(result, "chunks"), else: nil
  end

  defp recall_source_facts(result, payload) do
    if include_source_facts?(payload) do
      case Map.get(result, "source_facts") do
        nil ->
          nil

        source_facts when is_map(source_facts) ->
          Map.new(source_facts, fn {id, item} -> {id, recall_result(item)} end)

        _ ->
          nil
      end
    end
  end

  defp include_entities?(payload) do
    case Map.get(payload, "include") do
      nil -> true
      %{} = include -> !Map.has_key?(include, "entities") or include["entities"] != nil
      _ -> true
    end
  end

  defp include_chunks?(payload), do: get_in(payload, ["include", "chunks"]) != nil
  defp include_source_facts?(payload), do: get_in(payload, ["include", "source_facts"]) != nil
  defp include_facts?(payload), do: get_in(payload, ["include", "facts"]) != nil
  defp include_tool_calls?(payload), do: get_in(payload, ["include", "tool_calls"]) != nil

  defp normalize_disposition(disposition) do
    %{
      "skepticism" => disposition_value(disposition, "skepticism"),
      "literalism" => disposition_value(disposition, "literalism"),
      "empathy" => disposition_value(disposition, "empathy")
    }
  end

  defp disposition_value(disposition, key) do
    disposition
    |> case do
      %{} = value -> Map.get(value, key) || Map.get(value, String.to_atom(key))
      _ -> nil
    end
    |> Kernel.||(3)
  end

  defp maybe_background_disposition(result) do
    case Map.get(result, "disposition") do
      %{} = disposition -> normalize_disposition(disposition)
      _ -> nil
    end
  end

  defp format_entities([]), do: nil
  defp format_entities(entities), do: Enum.join(entities, ", ")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_included_map(map, _key, _value, false), do: map
  defp maybe_put_included_map(map, key, value, true), do: Map.put(map, key, value)

  defp normalize_timestamp(nil), do: nil
  defp normalize_timestamp("unset"), do: nil
  defp normalize_timestamp(""), do: nil
  defp normalize_timestamp(value), do: value

  defp fetch_required_string(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" do
          {:ok, trimmed}
        else
          {:error, Error.new(:invalid_request, %{message: "#{key} must be a non-empty string"})}
        end

      _ ->
        {:error, Error.new(:invalid_request, %{message: "#{key} must be a non-empty string"})}
    end
  end

  defp normalize_optional_string(payload, key) do
    case Map.get(payload, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, Error.new(:invalid_request, %{message: "#{key} must be a string or null"})}
    end
  end

  defp normalize_optional_boolean(payload, key, default) do
    case Map.get(payload, key, default) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, nil}
      _ -> {:error, Error.new(:invalid_request, %{message: "#{key} must be a boolean"})}
    end
  end

  defp normalize_boolean_param(nil, default), do: {:ok, default}
  defp normalize_boolean_param(value, _default) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean_param("true", _default), do: {:ok, true}
  defp normalize_boolean_param("false", _default), do: {:ok, false}

  defp normalize_boolean_param(_value, _default) do
    {:error, Error.new(:invalid_request, %{message: "active_only must be a boolean"})}
  end

  defp normalize_optional_integer(payload, key, default) do
    case Map.get(payload, key, default) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:ok, nil}
      _ -> {:error, Error.new(:invalid_request, %{message: "#{key} must be an integer"})}
    end
  end

  defp normalize_optional_map(payload, key, default) do
    case Map.get(payload, key, default) do
      value when is_map(value) -> {:ok, value}
      nil -> {:ok, nil}
      _ -> {:error, Error.new(:invalid_request, %{message: "#{key} must be an object"})}
    end
  end

  defp normalize_tags_field(tags) when is_list(tags), do: {:ok, tags}
  defp normalize_tags_field(nil), do: {:ok, []}

  defp normalize_tags_field(_tags) do
    {:error, Error.new(:invalid_request, %{message: "tags must be an array"})}
  end

  defp normalize_tags_param(nil), do: nil
  defp normalize_tags_param(tags) when is_list(tags), do: tags
  defp normalize_tags_param(tags) when is_binary(tags), do: [tags]
  defp normalize_tags_param(_tags), do: nil

  defp normalize_detail(detail) when detail in ["metadata", "content", "full"], do: detail
  defp normalize_detail(_detail), do: "full"

  defp collect_patch_attrs(payload, string_keys, integer_keys, boolean_keys, list_keys, map_keys) do
    with {:ok, attrs} <- collect_string_attrs(payload, string_keys, %{}),
         {:ok, attrs} <- collect_integer_attrs(payload, integer_keys, attrs),
         {:ok, attrs} <- collect_boolean_attrs(payload, boolean_keys, attrs),
         {:ok, attrs} <- collect_list_attrs(payload, list_keys, attrs),
         {:ok, attrs} <- collect_map_attrs(payload, map_keys, attrs) do
      {:ok, attrs}
    end
  end

  defp collect_string_attrs(payload, keys, acc) do
    Enum.reduce_while(keys, {:ok, acc}, fn key, {:ok, attrs} ->
      case Map.fetch(payload, key) do
        :error ->
          {:cont, {:ok, attrs}}

        {:ok, value} when is_binary(value) ->
          {:cont, {:ok, Map.put(attrs, key, value)}}

        {:ok, nil} ->
          {:cont, {:ok, attrs}}

        {:ok, _other} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: "#{key} must be a string"})}}
      end
    end)
  end

  defp collect_integer_attrs(payload, keys, acc) do
    Enum.reduce_while(keys, {:ok, acc}, fn key, {:ok, attrs} ->
      case Map.fetch(payload, key) do
        :error ->
          {:cont, {:ok, attrs}}

        {:ok, value} when is_integer(value) ->
          {:cont, {:ok, Map.put(attrs, key, value)}}

        {:ok, nil} ->
          {:cont, {:ok, attrs}}

        {:ok, _other} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: "#{key} must be an integer"})}}
      end
    end)
  end

  defp collect_boolean_attrs(payload, keys, acc) do
    Enum.reduce_while(keys, {:ok, acc}, fn key, {:ok, attrs} ->
      case Map.fetch(payload, key) do
        :error ->
          {:cont, {:ok, attrs}}

        {:ok, value} when is_boolean(value) ->
          {:cont, {:ok, Map.put(attrs, key, value)}}

        {:ok, nil} ->
          {:cont, {:ok, attrs}}

        {:ok, _other} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: "#{key} must be a boolean"})}}
      end
    end)
  end

  defp collect_list_attrs(payload, keys, acc) do
    Enum.reduce_while(keys, {:ok, acc}, fn key, {:ok, attrs} ->
      case Map.fetch(payload, key) do
        :error ->
          {:cont, {:ok, attrs}}

        {:ok, value} when is_list(value) ->
          {:cont, {:ok, Map.put(attrs, key, value)}}

        {:ok, nil} ->
          {:cont, {:ok, attrs}}

        {:ok, _other} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: "#{key} must be an array"})}}
      end
    end)
  end

  defp collect_map_attrs(payload, keys, acc) do
    Enum.reduce_while(keys, {:ok, acc}, fn key, {:ok, attrs} ->
      case Map.fetch(payload, key) do
        :error ->
          {:cont, {:ok, attrs}}

        {:ok, value} when is_map(value) ->
          {:cont, {:ok, Map.put(attrs, key, value)}}

        {:ok, nil} ->
          {:cont, {:ok, attrs}}

        {:ok, _other} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: "#{key} must be an object"})}}
      end
    end)
  end

  defp normalize_webhook_event_types(nil), do: {:ok, ["consolidation.completed"]}

  defp normalize_webhook_event_types(event_types) when is_list(event_types) do
    normalized =
      Enum.filter(event_types, fn
        value when is_binary(value) -> true
        _ -> false
      end)

    if length(normalized) == length(event_types) do
      {:ok, normalized}
    else
      {:error, Error.new(:invalid_request, %{message: "event_types must be a list of strings"})}
    end
  end

  defp normalize_webhook_event_types(_value) do
    {:error, Error.new(:invalid_request, %{message: "event_types must be a list of strings"})}
  end

  defp normalize_webhook_http_config(value, opts \\ [])

  defp normalize_webhook_http_config(nil, opts) do
    if Keyword.get(opts, :allow_nil, false), do: {:ok, %{}}, else: {:ok, default_http_config()}
  end

  defp normalize_webhook_http_config(%{} = http_config, _opts) do
    with {:ok, method} <- normalize_http_method(Map.get(http_config, "method", "POST")),
         {:ok, timeout_seconds} <-
           normalize_positive_integer(
             Map.get(http_config, "timeout_seconds", 30),
             "timeout_seconds"
           ),
         {:ok, headers} <- normalize_string_map(Map.get(http_config, "headers", %{}), "headers"),
         {:ok, params} <- normalize_string_map(Map.get(http_config, "params", %{}), "params") do
      {:ok,
       %{
         "method" => method,
         "timeout_seconds" => timeout_seconds,
         "headers" => headers,
         "params" => params
       }}
    end
  end

  defp normalize_webhook_http_config(_value, _opts) do
    {:error, Error.new(:invalid_request, %{message: "http_config must be an object or null"})}
  end

  defp normalize_http_method(value) when value in ["GET", "POST"], do: {:ok, value}

  defp normalize_http_method(_value) do
    {:error, Error.new(:invalid_request, %{message: "http_config.method must be GET or POST"})}
  end

  defp normalize_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(_value, field) do
    {:error, Error.new(:invalid_request, %{message: "#{field} must be a positive integer"})}
  end

  defp normalize_string_map(%{} = map, field) do
    if Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, map}
    else
      {:error,
       Error.new(:invalid_request, %{message: "#{field} must be an object with string values"})}
    end
  end

  defp normalize_string_map(_value, field) do
    {:error,
     Error.new(:invalid_request, %{message: "#{field} must be an object with string values"})}
  end

  defp normalize_limit(nil), do: {:ok, 50}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 and limit <= 200,
    do: {:ok, limit}

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> {:error, Error.new(:invalid_request, %{message: "limit must be an integer <= 200"})}
    end
  end

  defp normalize_limit(_limit) do
    {:error, Error.new(:invalid_request, %{message: "limit must be an integer <= 200"})}
  end

  defp normalize_offset(nil), do: {:ok, 0}

  defp normalize_offset(offset) when is_integer(offset) and offset >= 0,
    do: {:ok, offset}

  defp normalize_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {parsed, ""} ->
        normalize_offset(parsed)

      _ ->
        {:error, Error.new(:invalid_request, %{message: "offset must be a non-negative integer"})}
    end
  end

  defp normalize_offset(_offset) do
    {:error, Error.new(:invalid_request, %{message: "offset must be a non-negative integer"})}
  end

  defp normalize_cursor(nil), do: {:ok, nil}
  defp normalize_cursor(""), do: {:ok, nil}

  defp normalize_cursor(cursor) when is_binary(cursor) do
    case DateTime.from_iso8601(cursor) do
      {:ok, _datetime, _offset} ->
        {:ok, cursor}

      _ ->
        {:error, Error.new(:invalid_request, %{message: "cursor must be an ISO8601 timestamp"})}
    end
  end

  defp normalize_cursor(_cursor) do
    {:error, Error.new(:invalid_request, %{message: "cursor must be an ISO8601 timestamp"})}
  end

  defp response_http_config(%{} = http_config) do
    default_http_config()
    |> Map.merge(http_config)
    |> Map.update("headers", %{}, &(&1 || %{}))
    |> Map.update("params", %{}, &(&1 || %{}))
  end

  defp response_http_config(_http_config), do: default_http_config()

  defp default_http_config do
    %{"method" => "POST", "timeout_seconds" => 30, "headers" => %{}, "params" => %{}}
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_map_preserve_nil(map, nil_keys) do
    nil_keys = MapSet.new(nil_keys)

    map
    |> Enum.reject(fn {key, value} -> is_nil(value) and not MapSet.member?(nil_keys, key) end)
    |> Map.new()
  end

  defp normalize_observation_scopes(%{"observation_scopes" => scopes} = payload)
       when is_list(scopes) do
    tag_scopes =
      Enum.map(scopes, fn tags ->
        %{"tags" => tags}
      end)

    payload
    |> Map.delete("observation_scopes")
    |> Map.put("tag_scopes", tag_scopes)
  end

  defp normalize_observation_scopes(payload), do: payload

  defp decode_file_retain_request(request) when is_map(request), do: {:ok, request}

  defp decode_file_retain_request(request) when is_binary(request) do
    case Jason.decode(request) do
      {:ok, %{} = decoded} ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error,
         Error.new(:invalid_request, %{message: "file retain request must decode to an object"})}

      {:error, _reason} ->
        {:error,
         Error.new(:invalid_request, %{message: "file retain request must be valid JSON"})}
    end
  end

  defp decode_file_retain_request(nil), do: {:ok, %{}}

  defp decode_file_retain_request(_request) do
    {:error,
     Error.new(:invalid_request, %{message: "file retain request must be a JSON string or object"})}
  end

  defp normalize_file_inputs(files) do
    normalized =
      Enum.map(files, fn
        %Plug.Upload{} = upload ->
          %{
            "path" => upload.path,
            "filename" => upload.filename,
            "content_type" => upload.content_type
          }

        %{} = file ->
          # SECURITY: a file `path` is trusted ONLY from a server-produced
          # Plug.Upload (above). A client-supplied `path` in a JSON body is an
          # arbitrary host-file read (file_bytes/docling both File.read it), so it
          # is stripped here — inline JSON files without a real upload cannot
          # reference server paths.
          file |> stringify_keys() |> Map.delete("path")

        other ->
          other
      end)

    if Enum.all?(normalized, &is_map/1) and normalized != [] do
      {:ok, normalized}
    else
      {:error,
       Error.new(:invalid_request, %{message: "files payload must contain upload objects"})}
    end
  end

  defp validate_files_metadata_count(request, files) do
    case Map.get(request, "files_metadata") do
      nil ->
        :ok

      files_metadata when is_list(files_metadata) and length(files_metadata) == length(files) ->
        :ok

      files_metadata when is_list(files_metadata) ->
        {:error,
         Error.new(:invalid_request, %{
           message: "files_metadata count must match uploaded files count"
         })}

      _other ->
        {:error,
         Error.new(:invalid_request, %{message: "files_metadata must be a list when provided"})}
    end
  end

  defp apply_files_metadata(files, request) do
    case Map.get(request, "files_metadata") do
      nil ->
        {:ok, files}

      files_metadata when is_list(files_metadata) ->
        if Enum.all?(files_metadata, &is_map/1) do
          files =
            Enum.zip(files, files_metadata)
            |> Enum.map(fn {file, metadata} ->
              Map.merge(file, stringify_keys(metadata))
            end)

          {:ok, files}
        else
          {:error,
           Error.new(:invalid_request, %{message: "files_metadata entries must be objects"})}
        end
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp empty_based_on do
    %{"memories" => [], "mental_models" => [], "directives" => []}
  end

  defp empty_trace do
    %{"tool_calls" => [], "llm_calls" => []}
  end

  defp shape_reflect_trace(trace, payload) when is_map(trace) do
    %{
      "tool_calls" =>
        trace
        |> Map.get("tool_calls", [])
        |> Enum.map(&shape_reflect_tool_call(&1, payload)),
      "llm_calls" =>
        trace
        |> Map.get("llm_calls", [])
        |> Enum.map(&shape_reflect_llm_call/1)
    }
  end

  defp shape_reflect_trace(_trace, _payload), do: empty_trace()

  defp shape_reflect_tool_call(tool_call, payload) do
    %{
      "tool" => tool_call["tool"],
      "input" => Map.get(tool_call, "input", %{}),
      "output" =>
        if(get_in(payload, ["include", "tool_calls", "output"]) != false,
          do: Map.get(tool_call, "output"),
          else: nil
        ),
      "duration_ms" => Map.get(tool_call, "duration_ms", 0),
      "iteration" => Map.get(tool_call, "iteration", 0)
    }
    |> compact_map()
  end

  defp shape_reflect_llm_call(llm_call) do
    %{
      "scope" => reflect_llm_scope(llm_call),
      "duration_ms" => Map.get(llm_call, "duration_ms", 0)
    }
    |> compact_map()
  end

  defp reflect_llm_scope(%{"scope" => scope}) when is_binary(scope), do: scope
  defp reflect_llm_scope(%{"phase" => "plan"}), do: "agent_1"
  defp reflect_llm_scope(%{"phase" => "synthesize"}), do: "final"
  defp reflect_llm_scope(%{"phase" => "structured_output"}), do: "reflect_structured"
  defp reflect_llm_scope(%{"phase" => "final_rewrite"}), do: "final_rewrite"
  defp reflect_llm_scope(%{"phase" => phase}) when is_binary(phase), do: phase
  defp reflect_llm_scope(_llm_call), do: "unknown"
end
