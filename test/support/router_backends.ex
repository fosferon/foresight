defmodule Foresight.TestSupport.RouterBackend do
  @moduledoc false

  @behaviour Foresight.Backend

  alias Foresight.Error

  @impl true
  def retain(ctx, payload, _opts) do
    {:ok,
     %{
       "success" => true,
       "bank_id" => ctx.bank,
       "items_count" => length(payload["items"] || []),
       "async" => Map.get(payload, "async", false),
       "operation_id" => if(payload["async"], do: "op-1"),
       "operation_ids" => if(payload["async"], do: nil),
       "usage" => nil
     }}
  end

  @impl true
  def retain_files(ctx, payload, _opts) do
    {:ok,
     %{
       "bank_id" => ctx.bank,
       "operation_id" => "file-op-1",
       "operation_ids" => ["file-op-1"],
       "items_count" => length(payload["files"] || [])
     }}
  end

  @impl true
  def recall(_ctx, payload, _opts) do
    if payload["query"] == "no-match" do
      {:ok, %{"results" => [], "entities" => %{}}}
    else
      include_chunks = get_in(payload, ["include", "chunks"]) != nil
      include_source_facts = get_in(payload, ["include", "source_facts"]) != nil

      {:ok,
       %{
         "results" => [
           %{
             "id" => "memory-1",
             "content" => payload["query"],
             "text" => payload["query"],
             "type" => "world",
             "score" => 0.42,
             "entities" => ["Fosferon"],
             "context" => "chat",
             "occurred_start" => "2026-06-01T10:00:00Z",
             "occurred_end" => "2026-06-01T10:00:00Z",
             "mentioned_at" => "2026-06-01T10:00:00Z",
             "document_id" => "doc-1",
             "metadata" => %{"source" => "test"},
             "chunk_id" => if(include_chunks, do: "memory-1", else: nil),
             "tags" => payload["tags"] || [],
             "source_fact_ids" => if(include_source_facts, do: ["source-1"], else: nil)
           }
         ],
         "trace" =>
           if(payload["trace"],
             do: %{"query" => payload["query"], "num_results" => 1, "time_seconds" => 0.0}
           ),
         "entities" => %{
           "Fosferon" => %{
             "entity_id" => "entity-1",
             "canonical_name" => "Fosferon",
             "observations" => [
               %{"text" => payload["query"], "mentioned_at" => "2026-06-01T10:00:00Z"}
             ]
           }
         },
         "chunks" =>
           if(include_chunks,
             do: %{
               "memory-1" => %{
                 "id" => "memory-1",
                 "text" => payload["query"],
                 "chunk_index" => 0,
                 "truncated" => false
               }
             }
           ),
         "source_facts" =>
           if(include_source_facts,
             do: %{
               "source-1" => %{
                 "id" => "source-1",
                 "content" => "source fact",
                 "text" => "source fact",
                 "type" => "experience",
                 "entities" => ["Fosferon"],
                 "context" => "source",
                 "mentioned_at" => "2026-06-01T09:00:00Z",
                 "tags" => []
               }
             }
           )
       }}
    end
  end

  @impl true
  def reflect(_ctx, payload, _opts) do
    {:ok,
     %{
       "text" => "reflection: #{payload["query"]}",
       "based_on" => %{"memories" => [], "mental_models" => [], "directives" => []},
       "structured_output" => %{},
       "usage" => %{
         "input_tokens" => 10,
         "output_tokens" => 5,
         "total_tokens" => 15
       },
       "trace" => %{
         "tool_calls" => [
           %{
             "tool" => "recall",
             "phase" => "forced_initial_recall",
             "input" => %{"query" => payload["query"]},
             "output" => %{"result_ids" => ["memory-1"]},
             "duration_ms" => 12,
             "iteration" => 1,
             "extra" => "internal-only"
           }
         ],
         "llm_calls" => [
           %{
             "phase" => "synthesize",
             "prompt" => "reflect.v1",
             "duration_ms" => 34,
             "input_tokens" => 100,
             "output_tokens" => 20
           }
         ]
       }
     }}
  end

  @impl true
  def consolidate(ctx, payload, _opts) do
    {:ok,
     %{
       "success" => true,
       "bank_id" => ctx.bank,
       "observations_created" => Map.get(payload, "observations_created", 0),
       "scopes_consolidated" => Map.get(payload, "scopes_consolidated", 0),
       "operation" => "consolidate"
     }}
  end

  @impl true
  def list_memories(_ctx, params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => "memory-1",
           "content" => params["q"] || "hello",
           "type" => params["type"] || "observation"
         }
       ],
       "total" => 1,
       "limit" => Map.get(params, "limit", 100),
       "offset" => Map.get(params, "offset", 0)
     }}
  end

  @impl true
  def get_memory(_ctx, memory_id, _opts) do
    {:ok,
     %{
       "id" => memory_id,
       "text" => "hello",
       "content" => "hello",
       "context" => "chat",
       "type" => "observation",
       "tags" => ["project:alpha", "user:alice"],
       "metadata" => %{"source" => "test"},
       "history" => [],
       "entities" => ["Fosferon"],
       "source_fact_ids" => []
     }}
  end

  @impl true
  def get_memory_history(_ctx, _memory_id, _opts) do
    {:ok,
     [
       %{
         "previous_content" => "hello before update",
         "changed_at" => "2026-06-01T09:30:00Z",
         "source_facts" => [%{"id" => "memory-source-1", "text" => "source fact"}]
       }
     ]}
  end

  @impl true
  def delete_memory(_ctx, _bank_id, memory_id, _opts) do
    {:ok,
     %{
       "success" => true,
       "memory_id" => memory_id,
       "memory_units_deleted" => 1,
       "observations_deleted" => 0
     }}
  end

  @impl true
  def list_entities(_ctx, params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => "entity-1",
           "canonical_name" => "Fosferon",
           "mention_count" => 3
         }
       ],
       "total" => 1,
       "limit" => Map.get(params, "limit", 100),
       "offset" => Map.get(params, "offset", 0)
     }}
  end

  @impl true
  def entity_graph(_ctx, params, _opts) do
    {:ok,
     %{
       "nodes" => [
         %{
           "data" => %{
             "id" => "entity-1",
             "label" => "Fosferon",
             "mentionCount" => 3,
             "color" => "#42a5f5"
           }
         },
         %{
           "data" => %{
             "id" => "entity-2",
             "label" => "Athens",
             "mentionCount" => 1,
             "color" => "#90caf9"
           }
         }
       ],
       "edges" => [
         %{
           "data" => %{
             "id" => "entity-1-entity-2",
             "source" => "entity-1",
             "target" => "entity-2",
             "linkType" => "cooccurrence",
             "weight" => 2,
             "color" => "#ffd700",
             "lineStyle" => "solid",
             "lastCooccurred" => "2026-06-01T10:00:00Z"
           }
         }
       ],
       "total_entities" => 2,
       "total_edges" => 1,
       "limit" => Map.get(params, "limit", 100)
     }}
  end

  @impl true
  def get_entity(_ctx, entity_id, _opts) do
    {:ok,
     %{
       "id" => entity_id,
       "canonical_name" => "Fosferon",
       "mention_count" => 3,
       "first_seen" => "2026-06-01T09:00:00Z",
       "last_seen" => "2026-06-01T10:00:00Z",
       "metadata" => nil,
       "observations" => [%{"text" => "hello", "mentioned_at" => "2026-06-01T10:00:00Z"}]
     }}
  end

  @impl true
  def list_tags(_ctx, params, _opts) do
    items =
      case params["q"] do
        "project:*" -> [%{"tag" => "project:alpha", "count" => 2}]
        _ -> [%{"tag" => "project:alpha", "count" => 2}, %{"tag" => "user:alice", "count" => 1}]
      end

    {:ok,
     %{
       "items" => items,
       "total" => length(items),
       "limit" => Map.get(params, "limit", 100),
       "offset" => Map.get(params, "offset", 0)
     }}
  end

  @impl true
  def list_directives(_ctx, bank_id, params, _opts) do
    directives =
      [
        %{
          "id" => "directive-1",
          "bank_id" => bank_id,
          "name" => "Be concise",
          "content" => "Keep responses concise.",
          "priority" => 1,
          "is_active" => true,
          "tags" => Map.get(params, "tags", []),
          "created_at" => "2026-06-01T10:00:00Z",
          "updated_at" => "2026-06-01T10:00:00Z"
        }
      ]

    {:ok, %{"items" => directives, "total" => length(directives)}}
  end

  @impl true
  def get_directive(_ctx, bank_id, directive_id, _opts) do
    {:ok,
     %{
       "id" => directive_id,
       "bank_id" => bank_id,
       "name" => "Be concise",
       "content" => "Keep responses concise.",
       "priority" => 1,
       "is_active" => true,
       "tags" => ["project:alpha"],
       "created_at" => "2026-06-01T10:00:00Z",
       "updated_at" => "2026-06-01T10:00:00Z"
     }}
  end

  @impl true
  def create_directive(_ctx, bank_id, attrs, _opts) do
    {:ok,
     attrs
     |> Map.put("id", "directive-created")
     |> Map.put("bank_id", bank_id)
     |> Map.put("created_at", "2026-06-01T10:00:00Z")
     |> Map.put("updated_at", "2026-06-01T10:00:00Z")}
  end

  @impl true
  def update_directive(_ctx, bank_id, directive_id, attrs, _opts) do
    {:ok,
     attrs
     |> Map.put_new("name", "Updated directive")
     |> Map.put_new("content", "Updated content.")
     |> Map.put_new("priority", 0)
     |> Map.put_new("is_active", true)
     |> Map.put_new("tags", [])
     |> Map.put("id", directive_id)
     |> Map.put("bank_id", bank_id)
     |> Map.put("created_at", "2026-06-01T10:00:00Z")
     |> Map.put("updated_at", "2026-06-01T10:01:00Z")}
  end

  @impl true
  def delete_directive(_ctx, _bank_id, _directive_id, _opts), do: {:ok, %{"deleted" => true}}

  @impl true
  def list_mental_models(_ctx, bank_id, params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => "mental-model:customer-sentiment",
           "bank_id" => bank_id,
           "name" => "Customer sentiment",
           "source_query" => "Summarize customer sentiment",
           "content" => "Sentiment is improving.",
           "tags" => Map.get(params, "tags", []),
           "max_tokens" => 2048,
           "trigger" => %{"mode" => "full"},
           "created_at" => "2026-06-01T10:00:00Z"
         }
       ]
     }}
  end

  @impl true
  def get_mental_model(_ctx, bank_id, mental_model_id, params, _opts) do
    detail = Map.get(params, "detail", "full")

    {:ok,
     %{
       "id" => mental_model_id,
       "bank_id" => bank_id,
       "name" => "Customer sentiment",
       "source_query" => "Summarize customer sentiment",
       "content" => if(detail == "metadata", do: nil, else: "Sentiment is improving."),
       "tags" => ["project:alpha"],
       "max_tokens" => 2048,
       "trigger" => %{"mode" => "full"},
       "created_at" => "2026-06-01T10:00:00Z",
       "reflect_response" => if(detail == "full", do: %{"text" => "Sentiment is improving."}),
       "is_stale" => if(detail == "full", do: false)
     }}
  end

  @impl true
  def get_mental_model_history(_ctx, _bank_id, _mental_model_id, _opts) do
    {:ok,
     [
       %{
         "previous_content" => "Sentiment was mixed.",
         "changed_at" => "2026-06-01T09:30:00Z",
         "previous_reflect_response" => %{
           "based_on" => %{"memories" => [], "mental_models" => [], "directives" => []}
         }
       }
     ]}
  end

  @impl true
  def create_mental_model(_ctx, bank_id, attrs, _opts) do
    mental_model_id = attrs["id"] || "mental-model:generated"

    {:ok,
     %{
       "mental_model_id" => mental_model_id,
       "operation_id" => "mental-model-create-op:#{bank_id}"
     }}
  end

  @impl true
  def update_mental_model(_ctx, bank_id, mental_model_id, attrs, _opts) do
    {:ok,
     attrs
     |> Map.put_new("name", "Customer sentiment")
     |> Map.put_new("source_query", "Summarize customer sentiment")
     |> Map.put_new("tags", [])
     |> Map.put_new("max_tokens", 2048)
     |> Map.put_new("trigger", %{"mode" => "full"})
     |> Map.put("id", mental_model_id)
     |> Map.put("bank_id", bank_id)
     |> Map.put(
       "content",
       "Pending mental model content generation for #{Map.get(attrs, "source_query", "Summarize customer sentiment")}"
     )
     |> Map.put("created_at", "2026-06-01T10:00:00Z")}
  end

  @impl true
  def delete_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, %{"deleted" => true}}

  @impl true
  def refresh_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, %{"operation_id" => "1", "status" => "queued"}}

  @impl true
  def bank_profile(_ctx, bank_id, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "name" => "Fosferon",
       "mission" => "Remember things",
       "disposition" => %{"skepticism" => 3, "literalism" => 3, "empathy" => 3}
     }}
  end

  @impl true
  def list_documents(_ctx, params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => params["q"] || "doc-1",
           "bank_id" => "fosferon",
           "memory_unit_count" => 2,
           "tags" => Map.get(params, "tags", [])
         }
       ],
       "total" => 1,
       "limit" => Map.get(params, "limit", 100),
       "offset" => Map.get(params, "offset", 0)
     }}
  end

  @impl true
  def get_document(_ctx, document_id, _opts) do
    {:ok,
     %{
       "id" => document_id,
       "bank_id" => "fosferon",
       "original_text" => "hello world",
       "content_hash" => "hash-1",
       "created_at" => "2026-06-01T10:00:00Z",
       "updated_at" => "2026-06-01T10:01:00Z",
       "memory_unit_count" => 2,
       "nodes_by_fact_type" => %{"observation" => 1, "world" => 1},
       "tags" => ["project:alpha"],
       "document_metadata" => %{"source" => "test"},
       "retain_params" => nil
     }}
  end

  @impl true
  def list_document_chunks(_ctx, document_id, params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "chunk_id" => "chunk-1",
           "document_id" => document_id,
           "bank_id" => "fosferon",
           "chunk_index" => 0,
           "chunk_text" => "hello world",
           "created_at" => "2026-06-01T10:00:00Z"
         }
       ],
       "total" => 1,
       "limit" => Map.get(params, "limit", 100),
       "offset" => Map.get(params, "offset", 0)
     }}
  end

  @impl true
  def list_audit_logs(_ctx, params, _opts) do
    {:ok,
     %{
       "bank_id" => "fosferon",
       "total" => 1,
       "limit" => Map.get(params, "limit", 50),
       "offset" => Map.get(params, "offset", 0),
       "items" => [
         %{
           "id" => "audit-1",
           "action" => Map.get(params, "action", "retain"),
           "transport" => Map.get(params, "transport", "backend"),
           "bank_id" => "fosferon",
           "started_at" => "2026-06-01T10:00:00Z",
           "ended_at" => "2026-06-01T10:00:01Z",
           "duration_ms" => 1000,
           "request" => %{"limit" => Map.get(params, "limit", 50)},
           "response" => %{"ok" => true},
           "metadata" => %{"source" => "router-backend"}
         }
       ]
     }}
  end

  @impl true
  def audit_log_stats(_ctx, params, _opts) do
    {:ok,
     %{
       "bank_id" => "fosferon",
       "period" => Map.get(params, "period", "7d"),
       "trunc" => "day",
       "start" => "2026-05-25T00:00:00Z",
       "buckets" => [
         %{
           "time" => "2026-06-01T00:00:00Z",
           "actions" => %{Map.get(params, "action", "retain") => 1},
           "total" => 1
         }
       ]
     }}
  end

  @impl true
  def update_document(_ctx, _bank_id, _document_id, _attrs, _opts),
    do: {:ok, %{"success" => true}}

  @impl true
  def delete_document(_ctx, _bank_id, document_id, _opts) do
    {:ok,
     %{
       "success" => true,
       "message" =>
         "Document '#{document_id}' and 2 associated memory units deleted successfully",
       "document_id" => document_id,
       "memory_units_deleted" => 2
     }}
  end

  @impl true
  def reprocess_document(_ctx, _bank_id, _document_id, _opts) do
    {:ok, %{"success" => true, "operation_id" => "reprocess-op-1", "items_count" => 1}}
  end

  @impl true
  def memory_graph(_ctx, params, _opts) do
    {:ok,
     %{
       "nodes" => [
         %{
           "data" => %{
             "id" => "memory-1",
             "label" => "Fosferon remembers Athens",
             "text" => "Fosferon remembers Athens",
             "date" => "2026-06-01T10:00:00Z",
             "context" => "chat",
             "entities" => "Fosferon, Athens",
             "color" => "#42a5f5"
           }
         }
       ],
       "edges" => [
         %{
           "data" => %{
             "id" => "memory-1-memory-1-semantic",
             "source" => "memory-1",
             "target" => "memory-1",
             "linkType" => "semantic",
             "weight" => 1.0,
             "entityName" => "",
             "color" => "#ff69b4",
             "lineStyle" => "solid"
           }
         }
       ],
       "table_rows" => [
         %{
           "id" => "memory-1",
           "text" => "Fosferon remembers Athens",
           "context" => "chat",
           "occurred_start" => nil,
           "occurred_end" => nil,
           "mentioned_at" => "2026-06-01T10:00:00Z",
           "date" => "2026-06-01 10:00",
           "entities" => "Fosferon, Athens",
           "document_id" => params["document_id"],
           "chunk_id" => params["chunk_id"],
           "fact_type" => Map.get(params, "type", "world"),
           "tags" => Map.get(params, "tags", []),
           "created_at" => "2026-06-01T10:00:00Z",
           "proof_count" => 1
         }
       ],
       "total_units" => 1,
       "limit" => Map.get(params, "limit", 100)
     }}
  end

  @impl true
  def get_chunk(_ctx, chunk_id, _opts) do
    {:ok,
     %{
       "chunk_id" => chunk_id,
       "document_id" => "doc-1",
       "bank_id" => "fosferon",
       "chunk_index" => 0,
       "chunk_text" => "hello world",
       "created_at" => "2026-06-01T10:00:00Z"
     }}
  end

  @impl true
  def list_operations(_ctx, params, _opts) do
    {:ok,
     %{
       "bank_id" => "fosferon",
       "operations" => [
         %{
           "id" => "op-1",
           "task_type" => "retain",
           "items_count" => 2,
           "created_at" => "2026-06-01T10:00:00Z",
           "status" => "pending",
           "error_message" => nil,
           "retry_count" => 0,
           "next_retry_at" => nil
         }
       ],
       "total" => 1,
       "limit" => Map.get(params, "limit", 100),
       "offset" => Map.get(params, "offset", 0)
     }}
  end

  @impl true
  def get_operation(_ctx, operation_id, _opts) do
    {:ok,
     %{
       "operation_id" => operation_id,
       "status" => "completed",
       "operation_type" => "retain",
       "created_at" => "2026-06-01T10:00:00Z",
       "updated_at" => "2026-06-01T10:01:00Z",
       "completed_at" => "2026-06-01T10:01:00Z",
       "error_message" => nil,
       "retry_count" => 0,
       "next_retry_at" => nil,
       "task_payload" => %{"items" => [%{"content" => "hello"}], "async" => false}
     }}
  end

  @impl true
  def cancel_operation(_ctx, operation_id, _opts) do
    {:ok,
     %{
       "success" => true,
       "message" => "Operation #{operation_id} cancelled",
       "operation_id" => operation_id
     }}
  end

  @impl true
  def retry_operation(_ctx, operation_id, _opts) do
    {:ok,
     %{
       "success" => true,
       "message" => "Operation #{operation_id} queued for retry",
       "operation_id" => operation_id
     }}
  end

  @impl true
  def recover_consolidation(_ctx, _bank_id, _opts), do: {:ok, %{"retried_count" => 2}}

  @impl true
  def clear_observations(_ctx, _bank_id, _opts), do: {:ok, %{"deleted_count" => 2}}

  @impl true
  def clear_memory_observations(_ctx, _bank_id, _memory_id, _opts),
    do: {:ok, %{"deleted_count" => 1}}

  @impl true
  def list_banks(_ctx, _opts) do
    {:ok, [%{"id" => "fosferon", "name" => "Fosferon"}]}
  end

  @impl true
  def put_bank(_ctx, bank_id, attrs, _opts) do
    {:ok, Map.merge(%{"id" => bank_id}, stringify_keys(attrs))}
  end

  @impl true
  def patch_bank(_ctx, bank_id, attrs, _opts) do
    {:ok, Map.merge(%{"id" => bank_id}, stringify_keys(attrs))}
  end

  @impl true
  def update_bank_disposition(_ctx, bank_id, disposition, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "name" => "Fosferon",
       "mission" => "Remember things",
       "background" => "Remember things",
       "disposition" => stringify_keys(disposition)
     }}
  end

  @impl true
  def add_bank_background(_ctx, _bank_id, content, _opts) do
    {:ok, %{"mission" => content, "background" => content}}
  end

  @impl true
  def delete_bank(_ctx, bank_id, _opts) do
    {:ok, %{"id" => bank_id, "deleted" => true, "deleted_count" => 21}}
  end

  @impl true
  def clear_bank_memories(_ctx, _bank_id, _params, _opts) do
    {:ok, %{"success" => true, "message" => nil, "deleted_count" => nil}}
  end

  @impl true
  def get_bank_config(_ctx, bank_id, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "config" => %{
         "recall_max_tokens" => 2048,
         "reflect_mission" => "Remember things",
         "llm_api_key" => "sk-router-secret"
       },
       "overrides" => %{}
     }}
  end

  @impl true
  def update_bank_config(_ctx, bank_id, updates, _opts) do
    overrides = Enum.reject(updates, fn {_key, value} -> is_nil(value) end) |> Map.new()

    {:ok,
     %{
       "bank_id" => bank_id,
       "config" =>
         Map.merge(
           %{
             "recall_max_tokens" => 2048,
             "reflect_mission" => "Remember things",
             "llm_api_key" => "sk-router-secret"
           },
           overrides
         ),
       "overrides" => overrides
     }}
  end

  @impl true
  def reset_bank_config(_ctx, bank_id, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "config" => %{
         "recall_max_tokens" => 2048,
         "reflect_mission" => "Remember things",
         "llm_api_key" => "sk-router-secret"
       },
       "overrides" => %{}
     }}
  end

  @impl true
  def create_webhook(_ctx, bank_id, attrs, _opts) do
    {:ok,
     %{
       "id" => "webhook-1",
       "bank_id" => bank_id,
       "url" => attrs["url"],
       "secret" => nil,
       "event_types" => Map.get(attrs, "event_types", ["consolidation.completed"]),
       "enabled" => Map.get(attrs, "enabled", true),
       "http_config" => Map.get(attrs, "http_config", %{}),
       "created_at" => "2026-06-24T18:00:00Z",
       "updated_at" => "2026-06-24T18:00:00Z"
     }}
  end

  @impl true
  def list_webhooks(_ctx, bank_id, _opts) do
    {:ok,
     [
       %{
         "id" => "webhook-1",
         "bank_id" => bank_id,
         "url" => "https://example.test/hook",
         "secret" => nil,
         "event_types" => ["consolidation.completed"],
         "enabled" => true,
         "http_config" => %{"method" => "POST", "timeout_seconds" => 30},
         "created_at" => "2026-06-24T18:00:00Z",
         "updated_at" => "2026-06-24T18:00:00Z"
       }
     ]}
  end

  @impl true
  def update_webhook(_ctx, bank_id, webhook_id, attrs, _opts) do
    {:ok,
     %{
       "id" => webhook_id,
       "bank_id" => bank_id,
       "url" => Map.get(attrs, "url", "https://example.test/hook"),
       "secret" => nil,
       "event_types" => Map.get(attrs, "event_types", ["consolidation.completed"]),
       "enabled" => Map.get(attrs, "enabled", true),
       "http_config" =>
         Map.get(attrs, "http_config", %{"method" => "POST", "timeout_seconds" => 30}),
       "created_at" => "2026-06-24T18:00:00Z",
       "updated_at" => "2026-06-24T18:05:00Z"
     }}
  end

  @impl true
  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts), do: {:ok, %{"success" => true}}

  @impl true
  def list_webhook_deliveries(_ctx, _bank_id, webhook_id, params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => "delivery-1",
           "webhook_id" => webhook_id,
           "url" => "https://example.test/hook",
           "event_type" => "consolidation.completed",
           "status" => "failed",
           "attempts" => 2,
           "next_retry_at" => nil,
           "last_error" => "timeout",
           "last_response_status" => nil,
           "last_response_body" => nil,
           "last_attempt_at" => "2026-06-24T18:03:00Z",
           "created_at" => "2026-06-24T18:01:00Z",
           "updated_at" => "2026-06-24T18:03:00Z"
         }
       ],
       "next_cursor" => Map.get(params, "cursor")
     }}
  end

  @impl true
  def export_bank_template(_ctx, _bank_id, _opts) do
    {:ok,
     %{
       "version" => "1",
       "bank" => %{
         "reflect_mission" => "Remember things",
         "recall_max_tokens" => 2048,
         "disposition_empathy" => 4
       },
       "mental_models" => [
         %{
           "id" => "mental-model:customer-sentiment",
           "name" => "Customer Sentiment Overview",
           "source_query" => "Summarize customer sentiment trends",
           "tags" => ["support"],
           "max_tokens" => 2048,
           "trigger" => %{"refresh_after_consolidation" => true}
         }
       ],
       "directives" => [
         %{"name" => "Always be empathetic", "content" => "Lead with empathy.", "priority" => 10}
       ]
     }}
  end

  @impl true
  def import_bank_template(_ctx, bank_id, manifest, _opts) do
    directives = List.wrap(manifest["directives"])
    mental_models = List.wrap(manifest["mental_models"])

    {:ok,
     %{
       "bank_id" => bank_id,
       "config_applied" => is_map(manifest["bank"]),
       "mental_models_created" => Enum.map(mental_models, & &1["id"]),
       "mental_models_updated" => [],
       "directives_created" => Enum.map(directives, & &1["name"]),
       "directives_updated" => [],
       "operation_ids" => [],
       "dry_run" => Map.get(manifest, "dry_run", false)
     }}
  end

  @impl true
  def bank_stats(_ctx, bank_id, _opts) do
    {:ok,
     %{
       "id" => bank_id,
       "memory_units" => 0,
       "last_consolidated_at" => "2026-06-02T08:11:34.054764+00:00",
       "pending_operations" => 0,
       "failed_operations" => 0,
       "operations_by_status" => %{},
       "pending_consolidation" => 0,
       "failed_consolidation" => 0,
       "total_documents" => 0,
       "total_links" => 0,
       "total_nodes" => 0,
       "total_observations" => 0,
       "nodes_by_fact_type" => %{},
       "links_by_link_type" => %{},
       "links_by_fact_type" => %{},
       "links_breakdown" => %{}
     }}
  end

  @impl true
  def memories_timeseries(_ctx, bank_id, period, time_field, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "period" => period,
       "trunc" =>
         if(period == "1h",
           do: "minute",
           else: if(period in ["12h", "1d"], do: "hour", else: "day")
         ),
       "time_field" => time_field,
       "buckets" => [
         %{
           "time" => "2026-06-01T00:00:00Z",
           "world" => 1,
           "experience" => 2,
           "observation" => 3
         },
         %{
           "time" => "2026-06-02T00:00:00Z",
           "world" => 0,
           "experience" => 1,
           "observation" => 0
         }
       ]
     }}
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end

defmodule Foresight.TestSupport.RecordedContractBackend do
  @moduledoc false

  @behaviour Foresight.Backend

  alias Foresight.TestSupport.RouterBackend

  @impl true
  def retain(_ctx, _payload, _opts), do: {:ok, recorded_fixture!("retain_async.json")}

  @impl true
  def retain_files(_ctx, _payload, _opts), do: {:ok, recorded_fixture!("files_retain.json")}

  @impl true
  def recall(_ctx, _payload, _opts), do: {:ok, recorded_fixture!("recall.json")}

  @impl true
  def reflect(_ctx, _payload, _opts), do: {:ok, recorded_fixture!("reflect.json")}

  @impl true
  def consolidate(_ctx, _payload, _opts), do: {:ok, recorded_fixture!("consolidate_trigger.json")}

  @impl true
  def list_memories(_ctx, _params, _opts), do: {:ok, recorded_fixture!("memories_list.json")}

  @impl true
  def get_memory(_ctx, _memory_id, _opts), do: {:ok, recorded_fixture!("memory_get.json")}

  @impl true
  def list_entities(_ctx, _params, _opts), do: {:ok, recorded_fixture!("entities_list.json")}

  @impl true
  def entity_graph(_ctx, _params, _opts), do: {:ok, recorded_fixture!("entity_graph.json")}

  @impl true
  def get_entity(_ctx, _entity_id, _opts), do: {:ok, recorded_fixture!("entity_get.json")}

  @impl true
  def list_tags(ctx, params, opts), do: RouterBackend.list_tags(ctx, params, opts)

  @impl true
  def list_directives(_ctx, _bank_id, _params, _opts),
    do: {:ok, recorded_fixture!("directives_list.json")}

  @impl true
  def get_directive(_ctx, _bank_id, _directive_id, _opts),
    do: {:ok, recorded_fixture!("directive_get.json")}

  @impl true
  def create_directive(_ctx, _bank_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("directive_create.json")}

  @impl true
  def update_directive(_ctx, _bank_id, _directive_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("directive_patch.json")}

  @impl true
  def delete_directive(_ctx, _bank_id, _directive_id, _opts),
    do: {:ok, recorded_fixture!("directive_delete.json")}

  @impl true
  def list_mental_models(_ctx, _bank_id, _params, _opts),
    do: {:ok, recorded_fixture!("mental_models_list.json")}

  @impl true
  def get_mental_model(_ctx, _bank_id, _mental_model_id, _params, _opts),
    do: {:ok, recorded_fixture!("mental_model_get.json")}

  @impl true
  def get_mental_model_history(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, recorded_fixture!("mental_model_history.json")}

  @impl true
  def get_memory_history(_ctx, _memory_id, _opts),
    do: {:ok, recorded_fixture!("memory_history.json")}

  @impl true
  def delete_memory(_ctx, _bank_id, memory_id, _opts) do
    {:ok,
     %{
       "success" => true,
       "memory_id" => memory_id,
       "memory_units_deleted" => 1,
       "observations_deleted" => 0
     }}
  end

  @impl true
  def create_mental_model(_ctx, _bank_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("mental_model_create.json")}

  @impl true
  def update_mental_model(_ctx, _bank_id, _mental_model_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("mental_model_patch.json")}

  @impl true
  def delete_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, recorded_fixture!("mental_model_delete.json")}

  @impl true
  def refresh_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, recorded_fixture!("mental_model_refresh.json")}

  @impl true
  def bank_profile(_ctx, _bank_id, _opts), do: {:ok, recorded_fixture!("bank_profile.json")}

  @impl true
  def list_documents(_ctx, _params, _opts), do: {:ok, recorded_fixture!("documents_list.json")}

  @impl true
  def get_document(_ctx, _document_id, _opts), do: {:ok, recorded_fixture!("document_get.json")}

  @impl true
  def list_document_chunks(_ctx, _document_id, _params, _opts),
    do: {:ok, recorded_fixture!("document_chunks.json")}

  @impl true
  def list_audit_logs(ctx, params, opts), do: RouterBackend.list_audit_logs(ctx, params, opts)

  @impl true
  def audit_log_stats(ctx, params, opts), do: RouterBackend.audit_log_stats(ctx, params, opts)

  @impl true
  def update_document(_ctx, _bank_id, _document_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("document_patch.json")}

  @impl true
  def delete_document(_ctx, _bank_id, _document_id, _opts),
    do: {:ok, recorded_fixture!("document_delete.json")}

  @impl true
  def reprocess_document(_ctx, _bank_id, _document_id, _opts),
    do: {:ok, recorded_fixture!("document_reprocess.json")}

  @impl true
  def memory_graph(_ctx, _params, _opts), do: {:ok, recorded_fixture!("memory_graph.json")}

  @impl true
  def get_chunk(_ctx, _chunk_id, _opts), do: {:ok, recorded_fixture!("chunk_get.json")}

  @impl true
  def list_operations(ctx, params, opts), do: RouterBackend.list_operations(ctx, params, opts)

  @impl true
  def get_operation(ctx, operation_id, opts),
    do: RouterBackend.get_operation(ctx, operation_id, opts)

  @impl true
  def cancel_operation(ctx, operation_id, opts),
    do: RouterBackend.cancel_operation(ctx, operation_id, opts)

  @impl true
  def retry_operation(ctx, operation_id, opts),
    do: RouterBackend.retry_operation(ctx, operation_id, opts)

  @impl true
  def recover_consolidation(ctx, bank_id, opts),
    do: RouterBackend.recover_consolidation(ctx, bank_id, opts)

  @impl true
  def clear_observations(_ctx, _bank_id, _opts),
    do: {:ok, recorded_fixture!("clear_observations.json")}

  @impl true
  def clear_memory_observations(_ctx, _bank_id, _memory_id, _opts),
    do: {:ok, recorded_fixture!("clear_memory_observations.json")}

  @impl true
  def list_banks(_ctx, _opts), do: {:ok, recorded_fixture!("banks_list.json")["banks"]}

  @impl true
  def put_bank(_ctx, _bank_id, _attrs, _opts), do: {:ok, recorded_fixture!("bank_put.json")}

  @impl true
  def patch_bank(_ctx, _bank_id, _attrs, _opts), do: {:ok, recorded_fixture!("bank_patch.json")}

  @impl true
  def update_bank_disposition(ctx, bank_id, disposition, opts),
    do: RouterBackend.update_bank_disposition(ctx, bank_id, disposition, opts)

  @impl true
  def add_bank_background(ctx, bank_id, content, opts),
    do: RouterBackend.add_bank_background(ctx, bank_id, content, opts)

  @impl true
  def delete_bank(_ctx, _bank_id, _opts), do: {:ok, recorded_fixture!("bank_delete.json")}

  @impl true
  def clear_bank_memories(_ctx, _bank_id, _params, _opts),
    do: {:ok, recorded_fixture!("clear_memories.json")}

  @impl true
  def get_bank_config(ctx, bank_id, opts), do: RouterBackend.get_bank_config(ctx, bank_id, opts)

  @impl true
  def update_bank_config(ctx, bank_id, updates, opts),
    do: RouterBackend.update_bank_config(ctx, bank_id, updates, opts)

  @impl true
  def reset_bank_config(ctx, bank_id, opts),
    do: RouterBackend.reset_bank_config(ctx, bank_id, opts)

  @impl true
  def create_webhook(_ctx, _bank_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("webhook_create.json")}

  @impl true
  def list_webhooks(_ctx, _bank_id, _opts),
    do: {:ok, recorded_fixture!("webhooks_list.json")["items"]}

  @impl true
  def update_webhook(_ctx, _bank_id, _webhook_id, _attrs, _opts),
    do: {:ok, recorded_fixture!("webhook_patch.json")}

  @impl true
  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts),
    do: {:ok, recorded_fixture!("webhook_delete.json")}

  @impl true
  def list_webhook_deliveries(_ctx, _bank_id, _webhook_id, _params, _opts),
    do: {:ok, recorded_fixture!("webhook_deliveries_list.json")}

  @impl true
  def export_bank_template(ctx, bank_id, opts),
    do: RouterBackend.export_bank_template(ctx, bank_id, opts)

  @impl true
  def import_bank_template(ctx, bank_id, manifest, opts),
    do: RouterBackend.import_bank_template(ctx, bank_id, manifest, opts)

  @impl true
  def bank_stats(_ctx, _bank_id, _opts), do: {:ok, recorded_fixture!("bank_stats.json")}

  @impl true
  def memories_timeseries(ctx, bank_id, period, time_field, opts),
    do: RouterBackend.memories_timeseries(ctx, bank_id, period, time_field, opts)

  defp recorded_fixture!(name) do
    "recorded_floor_contract"
    |> fixture_path(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp fixture_path(dir, name) do
    Path.expand("../../priv/foresight/fixtures/#{dir}/#{name}", __DIR__)
  end
end

defmodule Foresight.TestSupport.RouterErrorBackend do
  @moduledoc false

  @behaviour Foresight.Backend

  alias Foresight.Error

  @impl true
  def retain(_ctx, _payload, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "retain failed"})}

  @impl true
  def retain_files(_ctx, _payload, _opts),
    do: {:error, Error.new(:not_implemented, %{message: "file retain failed"})}

  @impl true
  def recall(_ctx, _query, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "recall failed"})}

  @impl true
  def reflect(_ctx, _query, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "reflect failed"})}

  @impl true
  def consolidate(_ctx, _payload, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "consolidate failed"})}

  @impl true
  def list_memories(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list memories failed"})}

  @impl true
  def get_memory(_ctx, _memory_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "get memory failed"})}

  @impl true
  def get_memory_history(_ctx, _memory_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "get memory history failed"})}

  @impl true
  def delete_memory(_ctx, _bank_id, _memory_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "memory not found"})}

  @impl true
  def list_entities(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list entities failed"})}

  @impl true
  def entity_graph(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "entity graph failed"})}

  @impl true
  def get_entity(_ctx, _entity_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "get entity failed"})}

  @impl true
  def list_tags(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list tags failed"})}

  @impl true
  def list_directives(_ctx, _bank_id, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list directives failed"})}

  @impl true
  def get_directive(_ctx, _bank_id, _directive_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "directive not found"})}

  @impl true
  def create_directive(_ctx, _bank_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "create directive failed"})}

  @impl true
  def update_directive(_ctx, _bank_id, _directive_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "update directive failed"})}

  @impl true
  def delete_directive(_ctx, _bank_id, _directive_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "directive not found"})}

  @impl true
  def list_mental_models(_ctx, _bank_id, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list mental models failed"})}

  @impl true
  def get_mental_model(_ctx, _bank_id, _mental_model_id, _params, _opts),
    do: {:error, Error.new(:not_found, %{message: "mental model not found"})}

  @impl true
  def get_mental_model_history(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "mental model not found"})}

  @impl true
  def create_mental_model(_ctx, _bank_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "create mental model failed"})}

  @impl true
  def update_mental_model(_ctx, _bank_id, _mental_model_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "update mental model failed"})}

  @impl true
  def delete_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "mental model not found"})}

  @impl true
  def refresh_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "mental model not found"})}

  @impl true
  def bank_profile(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "bank not found"})}

  @impl true
  def list_documents(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list documents failed"})}

  @impl true
  def get_document(_ctx, _document_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "get document failed"})}

  @impl true
  def list_document_chunks(_ctx, _document_id, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list document chunks failed"})}

  @impl true
  def list_audit_logs(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "list audit logs failed"})}

  @impl true
  def audit_log_stats(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "audit log stats failed"})}

  @impl true
  def update_document(_ctx, _bank_id, _document_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "update document failed"})}

  @impl true
  def delete_document(_ctx, _bank_id, _document_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "document not found"})}

  @impl true
  def reprocess_document(_ctx, _bank_id, _document_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "document not found"})}

  @impl true
  def memory_graph(_ctx, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "memory graph failed"})}

  @impl true
  def get_chunk(_ctx, _chunk_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "get chunk failed"})}

  @impl true
  def list_operations(_ctx, _params, _opts),
    do: {:error, Error.new(:timeout, %{message: "operations timed out"})}

  @impl true
  def get_operation(_ctx, _operation_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "operation not found"})}

  @impl true
  def cancel_operation(_ctx, _operation_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "operation cannot be cancelled"})}

  @impl true
  def retry_operation(_ctx, _operation_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "operation is not retryable"})}

  @impl true
  def recover_consolidation(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "recover consolidation failed"})}

  @impl true
  def clear_observations(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "clear observations failed"})}

  @impl true
  def clear_memory_observations(_ctx, _bank_id, _memory_id, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "clear memory observations failed"})}

  @impl true
  def list_banks(_ctx, _opts), do: {:error, Error.new(:timeout, %{message: "backend timed out"})}

  @impl true
  def put_bank(_ctx, _bank_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "bad bank payload"})}

  @impl true
  def patch_bank(_ctx, _bank_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "bad bank patch payload"})}

  @impl true
  def update_bank_disposition(_ctx, _bank_id, _disposition, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "update bank disposition failed"})}

  @impl true
  def add_bank_background(_ctx, _bank_id, _content, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "background update failed"})}

  @impl true
  def delete_bank(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:timeout, %{message: "delete timed out"})}

  @impl true
  def clear_bank_memories(_ctx, _bank_id, _params, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "clear memories failed"})}

  @impl true
  def get_bank_config(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "bank not found"})}

  @impl true
  def update_bank_config(_ctx, _bank_id, _updates, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "bad config payload"})}

  @impl true
  def reset_bank_config(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:timeout, %{message: "reset config timed out"})}

  @impl true
  def create_webhook(_ctx, _bank_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "bad webhook payload"})}

  @impl true
  def list_webhooks(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:timeout, %{message: "webhook list timed out"})}

  @impl true
  def update_webhook(_ctx, _bank_id, _webhook_id, _attrs, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "bad webhook patch payload"})}

  @impl true
  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "Webhook not found"})}

  @impl true
  def list_webhook_deliveries(_ctx, _bank_id, _webhook_id, _params, _opts),
    do: {:error, Error.new(:timeout, %{message: "webhook deliveries timed out"})}

  @impl true
  def export_bank_template(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:not_found, %{message: "bank not found"})}

  @impl true
  def import_bank_template(_ctx, _bank_id, _manifest, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "bad template payload"})}

  @impl true
  def bank_stats(_ctx, _bank_id, _opts),
    do: {:error, Error.new(:timeout, %{message: "stats timed out"})}

  @impl true
  def memories_timeseries(_ctx, _bank_id, _period, _time_field, _opts),
    do: {:error, Error.new(:invalid_request, %{message: "memories timeseries failed"})}
end

defmodule Foresight.TestSupport.RouterLlmErrorBackend do
  @moduledoc false

  alias Foresight.TestSupport.RouterBackend
  alias LlmCore.LLM.Error, as: LlmError

  defdelegate retain(ctx, payload, opts), to: RouterBackend
  defdelegate retain_files(ctx, payload, opts), to: RouterBackend
  defdelegate recall(ctx, payload, opts), to: RouterBackend
  defdelegate consolidate(ctx, payload, opts), to: RouterBackend
  defdelegate list_memories(ctx, params, opts), to: RouterBackend
  defdelegate get_memory(ctx, memory_id, opts), to: RouterBackend
  defdelegate get_memory_history(ctx, memory_id, opts), to: RouterBackend
  defdelegate delete_memory(ctx, bank_id, memory_id, opts), to: RouterBackend
  defdelegate list_entities(ctx, params, opts), to: RouterBackend
  defdelegate entity_graph(ctx, params, opts), to: RouterBackend
  defdelegate get_entity(ctx, entity_id, opts), to: RouterBackend
  defdelegate list_tags(ctx, params, opts), to: RouterBackend
  defdelegate list_directives(ctx, bank_id, params, opts), to: RouterBackend
  defdelegate get_directive(ctx, bank_id, directive_id, opts), to: RouterBackend
  defdelegate create_directive(ctx, bank_id, attrs, opts), to: RouterBackend
  defdelegate update_directive(ctx, bank_id, directive_id, attrs, opts), to: RouterBackend
  defdelegate delete_directive(ctx, bank_id, directive_id, opts), to: RouterBackend
  defdelegate list_mental_models(ctx, bank_id, params, opts), to: RouterBackend
  defdelegate get_mental_model(ctx, bank_id, mental_model_id, params, opts), to: RouterBackend
  defdelegate get_mental_model_history(ctx, bank_id, mental_model_id, opts), to: RouterBackend
  defdelegate create_mental_model(ctx, bank_id, attrs, opts), to: RouterBackend
  defdelegate update_mental_model(ctx, bank_id, mental_model_id, attrs, opts), to: RouterBackend
  defdelegate delete_mental_model(ctx, bank_id, mental_model_id, opts), to: RouterBackend
  defdelegate refresh_mental_model(ctx, bank_id, mental_model_id, opts), to: RouterBackend
  defdelegate bank_profile(ctx, bank_id, opts), to: RouterBackend
  defdelegate list_documents(ctx, params, opts), to: RouterBackend
  defdelegate get_document(ctx, document_id, opts), to: RouterBackend
  defdelegate list_document_chunks(ctx, document_id, params, opts), to: RouterBackend
  defdelegate list_audit_logs(ctx, params, opts), to: RouterBackend
  defdelegate audit_log_stats(ctx, params, opts), to: RouterBackend
  defdelegate update_document(ctx, bank_id, document_id, attrs, opts), to: RouterBackend
  defdelegate delete_document(ctx, bank_id, document_id, opts), to: RouterBackend
  defdelegate reprocess_document(ctx, bank_id, document_id, opts), to: RouterBackend
  defdelegate memory_graph(ctx, params, opts), to: RouterBackend
  defdelegate get_chunk(ctx, chunk_id, opts), to: RouterBackend
  defdelegate list_operations(ctx, params, opts), to: RouterBackend
  defdelegate get_operation(ctx, operation_id, opts), to: RouterBackend
  defdelegate cancel_operation(ctx, operation_id, opts), to: RouterBackend
  defdelegate retry_operation(ctx, operation_id, opts), to: RouterBackend
  defdelegate recover_consolidation(ctx, bank_id, opts), to: RouterBackend
  defdelegate clear_observations(ctx, bank_id, opts), to: RouterBackend
  defdelegate clear_memory_observations(ctx, bank_id, memory_id, opts), to: RouterBackend
  defdelegate list_banks(ctx, opts), to: RouterBackend
  defdelegate put_bank(ctx, bank_id, attrs, opts), to: RouterBackend
  defdelegate patch_bank(ctx, bank_id, attrs, opts), to: RouterBackend
  defdelegate update_bank_disposition(ctx, bank_id, disposition, opts), to: RouterBackend
  defdelegate add_bank_background(ctx, bank_id, content, opts), to: RouterBackend
  defdelegate delete_bank(ctx, bank_id, opts), to: RouterBackend
  defdelegate clear_bank_memories(ctx, bank_id, params, opts), to: RouterBackend
  defdelegate get_bank_config(ctx, bank_id, opts), to: RouterBackend
  defdelegate update_bank_config(ctx, bank_id, updates, opts), to: RouterBackend
  defdelegate reset_bank_config(ctx, bank_id, opts), to: RouterBackend
  defdelegate create_webhook(ctx, bank_id, attrs, opts), to: RouterBackend
  defdelegate list_webhooks(ctx, bank_id, opts), to: RouterBackend
  defdelegate update_webhook(ctx, bank_id, webhook_id, attrs, opts), to: RouterBackend
  defdelegate delete_webhook(ctx, bank_id, webhook_id, opts), to: RouterBackend

  defdelegate list_webhook_deliveries(ctx, bank_id, webhook_id, params, opts),
    to: RouterBackend

  defdelegate export_bank_template(ctx, bank_id, opts), to: RouterBackend
  defdelegate import_bank_template(ctx, bank_id, manifest, opts), to: RouterBackend
  defdelegate bank_stats(ctx, bank_id, opts), to: RouterBackend
  defdelegate memories_timeseries(ctx, bank_id, period, time_field, opts), to: RouterBackend

  def reflect(_ctx, _payload, _opts) do
    {:error,
     LlmError.new(:provider_error,
       message: "LM Studio rejected the configured model",
       provider: :lmstudio,
       details: %{code: "model_not_found", status: 400}
     )}
  end
end

defmodule Foresight.TestSupport.RouterContextBackend do
  @moduledoc false

  @behaviour Foresight.Backend

  def retain(ctx, payload, _opts) do
    {:ok,
     %{
       "success" => true,
       "bank_id" => ctx.bank,
       "items_count" => length(payload["items"] || []),
       "async" => false,
       "tenant_id" => ctx.tenant_id,
       "role_name" => ctx.role_name,
       "prefix" => ctx.prefix
     }}
  end

  def retain_files(ctx, payload, _opts) do
    {:ok,
     %{
       "bank_id" => ctx.bank,
       "operation_id" => "file-op-ctx",
       "operation_ids" => ["file-op-ctx"],
       "items_count" => length(payload["files"] || []),
       "tenant_id" => ctx.tenant_id,
       "role_name" => ctx.role_name,
       "prefix" => ctx.prefix
     }}
  end

  def recall(ctx, _payload, _opts) do
    {:ok,
     %{
       "results" => [
         %{
           "id" => "memory-1",
           "content" => "ctx",
           "text" => "ctx",
           "type" => "world",
           "metadata" => %{
             "tenant_id" => ctx.tenant_id,
             "role_name" => ctx.role_name,
             "prefix" => ctx.prefix
           }
         }
       ]
     }}
  end

  def reflect(ctx, payload, _opts) do
    {:ok,
     %{
       "text" => "reflection: #{payload["query"]}",
       "based_on" => %{"memories" => [], "mental_models" => [], "directives" => []},
       "structured_output" => %{},
       "tenant_id" => ctx.tenant_id,
       "role_name" => ctx.role_name,
       "prefix" => ctx.prefix
     }}
  end

  def consolidate(ctx, _payload, _opts) do
    {:ok,
     %{
       "success" => true,
       "bank_id" => ctx.bank,
       "tenant_id" => ctx.tenant_id,
       "role_name" => ctx.role_name,
       "prefix" => ctx.prefix
     }}
  end

  def list_memories(ctx, _params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => "memory-1",
           "content" => ctx.prefix,
           "context" => ctx.role_name,
           "type" => "observation",
           "entities" => [ctx.tenant_id]
         }
       ],
       "total" => 1,
       "limit" => 100,
       "offset" => 0
     }}
  end

  def get_memory(ctx, memory_id, _opts) do
    {:ok,
     %{
       "id" => memory_id,
       "text" => ctx.prefix,
       "content" => ctx.prefix,
       "context" => ctx.role_name,
       "history" => [],
       "entities" => [ctx.tenant_id],
       "source_fact_ids" => []
     }}
  end

  def get_memory_history(ctx, _memory_id, _opts) do
    {:ok,
     [
       %{
         "previous_content" => ctx.prefix || "ctx",
         "changed_at" => "2026-06-01T09:30:00Z",
         "source_facts" => [%{"id" => "source-1", "text" => ctx.tenant_id}]
       }
     ]}
  end

  def delete_memory(_ctx, _bank_id, memory_id, _opts) do
    {:ok,
     %{
       "success" => true,
       "memory_id" => memory_id,
       "memory_units_deleted" => 1,
       "observations_deleted" => 0
     }}
  end

  def list_entities(ctx, _params, _opts),
    do:
      {:ok,
       %{
         "items" => [
           %{
             "id" => ctx.prefix || "entity-default",
             "canonical_name" => ctx.tenant_id,
             "mention_count" => 1
           }
         ],
         "total" => 1,
         "limit" => 100,
         "offset" => 0
       }}

  def entity_graph(ctx, params, _opts) do
    {:ok,
     %{
       "nodes" => [
         %{
           "data" => %{
             "id" => ctx.prefix || "entity-default",
             "label" => ctx.tenant_id || "tenant",
             "mentionCount" => 1,
             "color" => "#42a5f5"
           }
         }
       ],
       "edges" => [],
       "total_entities" => 1,
       "total_edges" => 0,
       "limit" => Map.get(params, "limit", 100)
     }}
  end

  def get_entity(ctx, entity_id, _opts),
    do:
      {:ok,
       %{
         "id" => entity_id,
         "canonical_name" => ctx.tenant_id,
         "mention_count" => 1,
         "metadata" => nil,
         "observations" => [%{"text" => ctx.prefix, "mentioned_at" => nil}]
       }}

  def list_tags(ctx, _params, _opts) do
    {:ok,
     %{
       "items" => [%{"tag" => ctx.tenant_id, "count" => 1}],
       "total" => 1,
       "limit" => 100,
       "offset" => 0
     }}
  end

  def list_directives(ctx, bank_id, _params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => ctx.prefix || "directive-ctx",
           "bank_id" => bank_id,
           "name" => ctx.tenant_id,
           "content" => ctx.role_name || "",
           "priority" => 0,
           "is_active" => true,
           "tags" => [ctx.tenant_id]
         }
       ]
     }}
  end

  def get_directive(ctx, bank_id, directive_id, _opts) do
    {:ok,
     %{
       "id" => directive_id,
       "bank_id" => bank_id,
       "name" => ctx.tenant_id,
       "content" => ctx.role_name || "",
       "priority" => 0,
       "is_active" => true,
       "tags" => [ctx.tenant_id]
     }}
  end

  def create_directive(ctx, bank_id, attrs, _opts),
    do: {:ok, Map.merge(attrs, %{"id" => ctx.prefix || "directive-ctx", "bank_id" => bank_id})}

  def update_directive(ctx, bank_id, directive_id, attrs, _opts),
    do:
      {:ok,
       attrs
       |> Map.put("id", directive_id)
       |> Map.put("bank_id", bank_id)
       |> Map.put_new("name", ctx.tenant_id)
       |> Map.put_new("content", ctx.role_name || "")
       |> Map.put_new("priority", 0)
       |> Map.put_new("is_active", true)
       |> Map.put_new("tags", [ctx.tenant_id])}

  def delete_directive(_ctx, _bank_id, _directive_id, _opts), do: {:ok, %{"deleted" => true}}

  def list_mental_models(ctx, bank_id, _params, _opts) do
    {:ok,
     %{
       "items" => [
         %{
           "id" => ctx.prefix || "mental-model-ctx",
           "bank_id" => bank_id,
           "name" => ctx.tenant_id,
           "source_query" => ctx.role_name || "",
           "content" => ctx.prefix || "",
           "tags" => [ctx.tenant_id],
           "max_tokens" => 2048,
           "trigger" => %{}
         }
       ]
     }}
  end

  def get_mental_model(ctx, bank_id, mental_model_id, _params, _opts) do
    {:ok,
     %{
       "id" => mental_model_id,
       "bank_id" => bank_id,
       "name" => ctx.tenant_id,
       "source_query" => ctx.role_name || "",
       "content" => ctx.prefix || "",
       "tags" => [ctx.tenant_id],
       "max_tokens" => 2048,
       "trigger" => %{}
     }}
  end

  def get_mental_model_history(_ctx, _bank_id, _mental_model_id, _opts) do
    {:ok,
     [
       %{
         "previous_content" => "tenant snapshot",
         "changed_at" => "2026-06-01T09:30:00Z",
         "previous_reflect_response" => nil
       }
     ]}
  end

  def create_mental_model(ctx, bank_id, attrs, _opts),
    do:
      {:ok,
       %{
         "mental_model_id" => attrs["id"] || ctx.prefix || "mental-model-ctx",
         "operation_id" => "mental-model-create-op:#{bank_id}"
       }}

  def update_mental_model(ctx, bank_id, mental_model_id, attrs, _opts),
    do:
      {:ok,
       attrs
       |> Map.put("id", mental_model_id)
       |> Map.put("bank_id", bank_id)
       |> Map.put_new("name", ctx.tenant_id)
       |> Map.put_new("source_query", ctx.role_name || "")
       |> Map.put_new("content", ctx.prefix || "")
       |> Map.put_new("tags", [ctx.tenant_id])
       |> Map.put_new("max_tokens", 2048)
       |> Map.put_new("trigger", %{})}

  def delete_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, %{"deleted" => true}}

  def refresh_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: {:ok, %{"operation_id" => "1", "status" => "queued"}}

  def bank_profile(ctx, bank_id, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "tenant_id" => ctx.tenant_id,
         "prefix" => ctx.prefix,
         "background" => ctx.role_name
       }}

  def list_documents(ctx, _params, _opts),
    do:
      {:ok,
       %{
         "items" => [
           %{
             "id" => ctx.prefix || "doc-default",
             "bank_id" => ctx.bank,
             "memory_unit_count" => 1,
             "tags" => [ctx.tenant_id]
           }
         ],
         "total" => 1,
         "limit" => 100,
         "offset" => 0
       }}

  def get_document(ctx, document_id, _opts),
    do:
      {:ok,
       %{
         "id" => document_id,
         "bank_id" => ctx.bank,
         "original_text" => ctx.prefix || "",
         "content_hash" => nil,
         "created_at" => "2026-06-01T10:00:00Z",
         "updated_at" => "2026-06-01T10:00:00Z",
         "memory_unit_count" => 1,
         "nodes_by_fact_type" => nil,
         "tags" => [ctx.tenant_id],
         "document_metadata" => nil,
         "retain_params" => nil
       }}

  def list_document_chunks(ctx, document_id, params, _opts),
    do:
      {:ok,
       %{
         "items" => [
           %{
             "chunk_id" => ctx.prefix || "chunk-ctx",
             "document_id" => document_id,
             "bank_id" => ctx.bank,
             "chunk_index" => 0,
             "chunk_text" => ctx.role_name || "",
             "created_at" => "2026-06-01T10:00:00Z"
           }
         ],
         "total" => 1,
         "limit" => Map.get(params, "limit", 100),
         "offset" => Map.get(params, "offset", 0)
       }}

  def list_audit_logs(ctx, params, _opts),
    do:
      {:ok,
       %{
         "bank_id" => ctx.bank,
         "total" => 1,
         "limit" => Map.get(params, "limit", 50),
         "offset" => Map.get(params, "offset", 0),
         "items" => [
           %{
             "id" => ctx.prefix || "audit-ctx",
             "action" => Map.get(params, "action", "retain"),
             "transport" => Map.get(params, "transport", "backend"),
             "bank_id" => ctx.bank,
             "started_at" => "2026-06-01T10:00:00Z",
             "ended_at" => "2026-06-01T10:00:01Z",
             "duration_ms" => 1000,
             "request" => %{"tenant_id" => ctx.tenant_id},
             "response" => %{"role_name" => ctx.role_name},
             "metadata" => %{"prefix" => ctx.prefix}
           }
         ]
       }}

  def audit_log_stats(ctx, params, _opts),
    do:
      {:ok,
       %{
         "bank_id" => ctx.bank,
         "period" => Map.get(params, "period", "7d"),
         "trunc" => "day",
         "start" => "2026-05-25T00:00:00Z",
         "buckets" => [
           %{
             "time" => "2026-06-01T00:00:00Z",
             "actions" => %{Map.get(params, "action", "retain") => 1},
             "total" => 1
           }
         ]
       }}

  def update_document(_ctx, _bank_id, _document_id, _attrs, _opts),
    do: {:ok, %{"success" => true}}

  def delete_document(_ctx, _bank_id, document_id, _opts),
    do:
      {:ok,
       %{
         "success" => true,
         "message" =>
           "Document '#{document_id}' and 1 associated memory units deleted successfully",
         "document_id" => document_id,
         "memory_units_deleted" => 1
       }}

  def reprocess_document(_ctx, _bank_id, _document_id, _opts),
    do: {:ok, %{"success" => true, "operation_id" => "ctx-reprocess-op", "items_count" => 1}}

  def memory_graph(ctx, params, _opts) do
    {:ok,
     %{
       "nodes" => [
         %{
           "data" => %{
             "id" => "memory-1",
             "label" => ctx.prefix || "ctx",
             "text" => ctx.prefix || "ctx",
             "date" => "2026-06-01T10:00:00Z",
             "context" => ctx.role_name || "",
             "entities" => ctx.tenant_id || "",
             "color" => "#42a5f5"
           }
         }
       ],
       "edges" => [],
       "table_rows" => [
         %{
           "id" => "memory-1",
           "text" => ctx.prefix || "ctx",
           "context" => ctx.role_name || "",
           "occurred_start" => nil,
           "occurred_end" => nil,
           "mentioned_at" => "2026-06-01T10:00:00Z",
           "date" => "2026-06-01 10:00",
           "entities" => ctx.tenant_id || "",
           "document_id" => nil,
           "chunk_id" => nil,
           "fact_type" => Map.get(params, "type", "world"),
           "tags" => [],
           "created_at" => "2026-06-01T10:00:00Z",
           "proof_count" => 1
         }
       ],
       "total_units" => 1,
       "limit" => Map.get(params, "limit", 100)
     }}
  end

  def get_chunk(ctx, chunk_id, _opts),
    do:
      {:ok,
       %{
         "chunk_id" => chunk_id,
         "document_id" => ctx.prefix || "doc-default",
         "bank_id" => ctx.bank,
         "chunk_index" => 0,
         "chunk_text" => ctx.role_name || "",
         "created_at" => "2026-06-01T10:00:00Z"
       }}

  def list_operations(ctx, _params, _opts),
    do:
      {:ok,
       %{
         "bank_id" => ctx.bank,
         "operations" => [
           %{
             "id" => "op-1",
             "status" => "pending",
             "task_type" => ctx.prefix,
             "error_message" => ctx.role_name,
             "next_retry_at" => ctx.tenant_id
           }
         ],
         "total" => 1,
         "limit" => 100,
         "offset" => 0
       }}

  def get_operation(ctx, operation_id, _opts),
    do:
      {:ok,
       %{
         "operation_id" => operation_id,
         "status" => "pending",
         "operation_type" => "retain",
         "task_payload" => %{
           "tenant_id" => ctx.tenant_id,
           "role_name" => ctx.role_name,
           "prefix" => ctx.prefix
         }
       }}

  def cancel_operation(_ctx, operation_id, _opts),
    do:
      {:ok,
       %{
         "success" => true,
         "message" => "Operation #{operation_id} cancelled",
         "operation_id" => operation_id
       }}

  def retry_operation(_ctx, operation_id, _opts),
    do:
      {:ok,
       %{
         "success" => true,
         "message" => "Operation #{operation_id} queued for retry",
         "operation_id" => operation_id
       }}

  def recover_consolidation(ctx, _bank_id, _opts),
    do: {:ok, %{"retried_count" => if(ctx.prefix, do: 1, else: 0)}}

  def clear_observations(_ctx, _bank_id, _opts), do: {:ok, %{"deleted_count" => 1}}

  def clear_memory_observations(_ctx, _bank_id, _memory_id, _opts),
    do: {:ok, %{"deleted_count" => 1}}

  def list_banks(ctx, _opts),
    do: {:ok, [%{"id" => ctx.prefix || "default", "tenant_id" => ctx.tenant_id}]}

  def put_bank(ctx, bank_id, _attrs, _opts),
    do:
      {:ok,
       %{
         "id" => bank_id,
         "name" => ctx.prefix,
         "mission" => ctx.tenant_id,
         "background" => ctx.role_name
       }}

  def patch_bank(ctx, bank_id, _attrs, _opts),
    do:
      {:ok,
       %{
         "id" => bank_id,
         "name" => ctx.prefix,
         "mission" => ctx.tenant_id,
         "background" => ctx.role_name
       }}

  def update_bank_disposition(ctx, bank_id, disposition, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "name" => ctx.prefix,
         "mission" => ctx.tenant_id,
         "background" => ctx.role_name,
         "disposition" => disposition
       }}

  def add_bank_background(ctx, bank_id, content, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "mission" => [ctx.tenant_id, content] |> Enum.reject(&is_nil/1) |> Enum.join(" "),
         "background" => [ctx.tenant_id, content] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
       }}

  def delete_bank(ctx, bank_id, _opts),
    do:
      {:ok,
       %{"id" => bank_id, "deleted" => true, "tenant_id" => ctx.tenant_id, "prefix" => ctx.prefix}}

  def clear_bank_memories(ctx, _bank_id, _params, _opts),
    do:
      {:ok,
       %{
         "success" => true,
         "message" => nil,
         "deleted_count" => nil,
         "tenant_id" => ctx.tenant_id,
         "prefix" => ctx.prefix
       }}

  def get_bank_config(ctx, bank_id, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "config" => %{"recall_max_tokens" => 2048, "tenant_id" => ctx.tenant_id},
         "overrides" => %{"prefix" => ctx.prefix}
       }}

  def update_bank_config(ctx, bank_id, updates, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "config" =>
           Map.merge(%{"recall_max_tokens" => 2048, "tenant_id" => ctx.tenant_id}, updates),
         "overrides" => Enum.reject(updates, fn {_key, value} -> is_nil(value) end) |> Map.new()
       }}

  def reset_bank_config(ctx, bank_id, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "config" => %{"recall_max_tokens" => 2048, "tenant_id" => ctx.tenant_id},
         "overrides" => %{}
       }}

  def create_webhook(ctx, bank_id, attrs, _opts),
    do:
      {:ok,
       %{
         "id" => ctx.prefix || "webhook-ctx",
         "bank_id" => bank_id,
         "url" => attrs["url"],
         "secret" => nil,
         "event_types" => Map.get(attrs, "event_types", ["consolidation.completed"]),
         "enabled" => Map.get(attrs, "enabled", true),
         "http_config" => Map.get(attrs, "http_config", %{}),
         "created_at" => "2026-06-24T18:00:00Z",
         "updated_at" => "2026-06-24T18:00:00Z"
       }}

  def list_webhooks(ctx, bank_id, _opts),
    do:
      {:ok,
       [
         %{
           "id" => ctx.prefix || "webhook-ctx",
           "bank_id" => bank_id,
           "url" => "https://example.test/#{ctx.tenant_id}",
           "secret" => nil,
           "event_types" => ["consolidation.completed"],
           "enabled" => true,
           "http_config" => %{"method" => "POST", "timeout_seconds" => 30},
           "created_at" => "2026-06-24T18:00:00Z",
           "updated_at" => "2026-06-24T18:00:00Z"
         }
       ]}

  def update_webhook(ctx, bank_id, webhook_id, attrs, _opts),
    do:
      {:ok,
       %{
         "id" => webhook_id,
         "bank_id" => bank_id,
         "url" => Map.get(attrs, "url", "https://example.test/#{ctx.tenant_id}"),
         "secret" => nil,
         "event_types" => Map.get(attrs, "event_types", ["consolidation.completed"]),
         "enabled" => Map.get(attrs, "enabled", true),
         "http_config" =>
           Map.get(attrs, "http_config", %{"method" => "POST", "timeout_seconds" => 30}),
         "created_at" => "2026-06-24T18:00:00Z",
         "updated_at" => "2026-06-24T18:05:00Z"
       }}

  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts), do: {:ok, %{"success" => true}}

  def list_webhook_deliveries(ctx, _bank_id, webhook_id, _params, _opts),
    do:
      {:ok,
       %{
         "items" => [
           %{
             "id" => "delivery-ctx",
             "webhook_id" => webhook_id,
             "url" => "https://example.test/#{ctx.tenant_id}",
             "event_type" => "consolidation.completed",
             "status" => "pending",
             "attempts" => 1,
             "next_retry_at" => nil,
             "last_error" => nil,
             "last_response_status" => nil,
             "last_response_body" => nil,
             "last_attempt_at" => "2026-06-24T18:03:00Z",
             "created_at" => "2026-06-24T18:01:00Z",
             "updated_at" => "2026-06-24T18:03:00Z"
           }
         ],
         "next_cursor" => nil
       }}

  def export_bank_template(ctx, _bank_id, _opts),
    do:
      {:ok,
       %{
         "version" => "1",
         "bank" => %{"reflect_mission" => "tenant #{ctx.tenant_id}"},
         "mental_models" => [],
         "directives" => []
       }}

  def import_bank_template(ctx, bank_id, manifest, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "config_applied" => is_map(manifest["bank"]),
         "mental_models_created" => [],
         "mental_models_updated" => [],
         "directives_created" => [],
         "directives_updated" => [],
         "operation_ids" => [],
         "dry_run" => Map.get(manifest, "dry_run", false),
         "tenant_id" => ctx.tenant_id
       }}

  def bank_stats(ctx, bank_id, _opts),
    do:
      {:ok,
       %{
         "id" => bank_id,
         "tenant_id" => ctx.tenant_id,
         "prefix" => ctx.prefix,
         "pending_operations" => 1
       }}

  def memories_timeseries(ctx, bank_id, period, time_field, _opts),
    do:
      {:ok,
       %{
         "bank_id" => bank_id,
         "period" => period,
         "trunc" => "day",
         "time_field" => time_field,
         "buckets" => [
           %{
             "time" => "2026-06-01T00:00:00Z",
             "world" => if(ctx.prefix, do: 1, else: 0),
             "experience" => 0,
             "observation" => 0
           }
         ]
       }}
end

defmodule Foresight.TestSupport.RouterMigrationProbeSpy do
  @moduledoc false

  def probe(source_prefix, target_prefix, bank_id, _opts) do
    {:ok,
     %{
       bank_id: bank_id,
       source_prefix: source_prefix,
       target_prefix: target_prefix,
       migration_policy: %{excluded_surfaces: [:audit_log]},
       target_provisioned: %{prefix: target_prefix, migrated_versions: [1, 2, 3]},
       source_audit: %{prefix: source_prefix, compatible?: true},
       parity_probe: %{clean?: true, source_memory_unit_count: 2, target_memory_unit_count: 2}
     }}
  end
end

defmodule Foresight.TestSupport.RouterMigrationOperationSpy do
  @moduledoc false

  def migrate(source_prefix, target_prefix, bank_id, _opts) do
    {:ok,
     %{
       bank_id: bank_id,
       source_prefix: source_prefix,
       target_prefix: target_prefix,
       migration_policy: %{excluded_surfaces: [:audit_log]},
       target_provisioned: %{prefix: target_prefix, migrated_versions: [1, 2, 3]},
       copied_banks: 1,
       copied_memory_units: 2,
       parity_probe: %{clean?: true}
     }}
  end
end

defmodule Foresight.TestSupport.RouterFailingMigrationProbeSpy do
  @moduledoc false

  def probe(source_prefix, target_prefix, bank_id, _opts) do
    {:error,
     {:migration_diagnostics,
      %{
        stage: :probe,
        failure_kind: :parity_probe_failed,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: %{excluded_surfaces: [:audit_log]},
        target_provisioned: %{prefix: target_prefix, migrated_versions: []},
        source_audit: %{prefix: source_prefix, compatible?: true},
        detail: %{clean?: false, missing_memory_unit_ids: ["mu-2"]}
      }}}
  end
end

defmodule Foresight.TestSupport.RouterFailingMigrationOperationSpy do
  @moduledoc false

  def migrate(source_prefix, target_prefix, bank_id, _opts) do
    {:error,
     {:migration_diagnostics,
      %{
        stage: :probe,
        failure_kind: :parity_probe_failed,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: %{excluded_surfaces: [:audit_log]},
        target_provisioned: %{prefix: target_prefix, migrated_versions: []},
        detail: %{clean?: false, missing_memory_unit_ids: ["mu-2"]}
      }}}
  end
end

defmodule Foresight.TestSupport.RouterMigrationDualSpy do
  @moduledoc false

  def migrate(source_prefix, target_prefix, bank_id, _opts) do
    {:ok,
     %{
       bank_id: bank_id,
       source_prefix: source_prefix,
       target_prefix: target_prefix,
       migration_policy: %{excluded_surfaces: [:audit_log]},
       target_provisioned: %{prefix: target_prefix, migrated_versions: [1, 2, 3]},
       copied_banks: 1,
       copied_memory_units: 2,
       parity_probe: %{clean?: true}
     }}
  end

  def probe(source_prefix, target_prefix, bank_id, _opts) do
    {:ok,
     %{
       bank_id: bank_id,
       source_prefix: source_prefix,
       target_prefix: target_prefix,
       migration_policy: %{excluded_surfaces: [:audit_log]},
       target_provisioned: %{prefix: target_prefix, migrated_versions: [1, 2, 3]},
       source_audit: %{prefix: source_prefix, compatible?: true},
       parity_probe: %{clean?: true, source_memory_unit_count: 2, target_memory_unit_count: 2}
     }}
  end
end
