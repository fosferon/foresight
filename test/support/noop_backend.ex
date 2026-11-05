defmodule Foresight.TestSupport.NoopBackend do
  @moduledoc false

  @behaviour Foresight.Backend

  @impl true
  def retain(_ctx, payload, _opts), do: {:ok, %{op: :retain, payload: payload}}

  @impl true
  def retain_files(_ctx, payload, _opts), do: {:ok, %{op: :retain_files, payload: payload}}

  @impl true
  def recall(_ctx, query, _opts), do: {:ok, %{op: :recall, query: query}}

  @impl true
  def reflect(_ctx, query, _opts), do: {:ok, %{op: :reflect, query: query}}

  @impl true
  def consolidate(_ctx, payload, _opts), do: {:ok, %{op: :consolidate, payload: payload}}

  @impl true
  def list_banks(_ctx, _opts), do: {:ok, []}

  @impl true
  def put_bank(_ctx, bank_id, attrs, _opts), do: {:ok, %{id: bank_id, attrs: attrs}}

  @impl true
  def patch_bank(_ctx, bank_id, attrs, _opts), do: {:ok, %{id: bank_id, attrs: attrs}}

  @impl true
  def update_bank_disposition(_ctx, bank_id, disposition, _opts),
    do: {:ok, %{op: :update_bank_disposition, id: bank_id, disposition: disposition}}

  @impl true
  def add_bank_background(_ctx, bank_id, content, _opts),
    do: {:ok, %{op: :add_bank_background, id: bank_id, mission: content, background: content}}

  @impl true
  def delete_bank(_ctx, bank_id, _opts), do: {:ok, %{id: bank_id}}

  @impl true
  def clear_bank_memories(_ctx, bank_id, params, _opts), do: {:ok, %{id: bank_id, params: params}}

  @impl true
  def get_bank_config(_ctx, bank_id, _opts) do
    {:ok, %{"bank_id" => bank_id, "config" => %{"recall_max_tokens" => 2048}, "overrides" => %{}}}
  end

  @impl true
  def update_bank_config(_ctx, bank_id, updates, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "config" => Map.merge(%{"recall_max_tokens" => 2048}, updates),
       "overrides" => Enum.reject(updates, fn {_k, v} -> is_nil(v) end) |> Map.new()
     }}
  end

  @impl true
  def reset_bank_config(_ctx, bank_id, _opts) do
    {:ok, %{"bank_id" => bank_id, "config" => %{"recall_max_tokens" => 2048}, "overrides" => %{}}}
  end

  @impl true
  def create_webhook(_ctx, bank_id, attrs, _opts),
    do: {:ok, %{"bank_id" => bank_id, "id" => "noop-webhook", "attrs" => attrs}}

  @impl true
  def list_webhooks(_ctx, _bank_id, _opts), do: {:ok, []}

  @impl true
  def update_webhook(_ctx, bank_id, webhook_id, attrs, _opts),
    do: {:ok, %{"bank_id" => bank_id, "id" => webhook_id, "attrs" => attrs}}

  @impl true
  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts), do: {:ok, %{"success" => true}}

  @impl true
  def list_webhook_deliveries(_ctx, _bank_id, _webhook_id, _params, _opts),
    do: {:ok, %{"items" => [], "next_cursor" => nil}}

  @impl true
  def export_bank_template(_ctx, _bank_id, _opts) do
    {:ok,
     %{
       "version" => "1",
       "bank" => %{"reflect_mission" => "Remember things"},
       "directives" => [],
       "mental_models" => []
     }}
  end

  @impl true
  def import_bank_template(_ctx, bank_id, manifest, _opts) do
    {:ok,
     %{
       "bank_id" => bank_id,
       "config_applied" => is_map(manifest["bank"]),
       "mental_models_created" => [],
       "mental_models_updated" => [],
       "directives_created" => [],
       "directives_updated" => [],
       "operation_ids" => [],
       "dry_run" => Map.get(manifest, "dry_run", false)
     }}
  end

  @impl true
  def bank_stats(_ctx, bank_id, _opts), do: {:ok, %{id: bank_id, count: 0}}

  @impl true
  def memories_timeseries(_ctx, bank_id, period, time_field, _opts),
    do: {:ok, %{op: :memories_timeseries, id: bank_id, period: period, time_field: time_field}}

  @impl true
  def list_memories(_ctx, params, _opts), do: {:ok, %{op: :list_memories, params: params}}

  @impl true
  def get_memory(_ctx, memory_id, _opts), do: {:ok, %{op: :get_memory, id: memory_id}}

  @impl true
  def get_memory_history(_ctx, memory_id, _opts),
    do: {:ok, %{op: :get_memory_history, id: memory_id}}

  @impl true
  def delete_memory(_ctx, bank_id, memory_id, _opts),
    do: {:ok, %{op: :delete_memory, bank_id: bank_id, id: memory_id}}

  @impl true
  def list_entities(_ctx, params, _opts), do: {:ok, %{op: :list_entities, params: params}}

  @impl true
  def entity_graph(_ctx, params, _opts), do: {:ok, %{op: :entity_graph, params: params}}

  @impl true
  def get_entity(_ctx, entity_id, _opts), do: {:ok, %{op: :get_entity, id: entity_id}}

  @impl true
  def list_tags(_ctx, params, _opts), do: {:ok, %{op: :list_tags, params: params}}

  @impl true
  def list_directives(_ctx, bank_id, params, _opts),
    do: {:ok, %{op: :list_directives, bank_id: bank_id, params: params}}

  @impl true
  def get_directive(_ctx, bank_id, directive_id, _opts),
    do: {:ok, %{op: :get_directive, bank_id: bank_id, id: directive_id}}

  @impl true
  def create_directive(_ctx, bank_id, attrs, _opts),
    do: {:ok, %{op: :create_directive, bank_id: bank_id, attrs: attrs}}

  @impl true
  def update_directive(_ctx, bank_id, directive_id, attrs, _opts),
    do: {:ok, %{op: :update_directive, bank_id: bank_id, id: directive_id, attrs: attrs}}

  @impl true
  def delete_directive(_ctx, bank_id, directive_id, _opts),
    do: {:ok, %{op: :delete_directive, bank_id: bank_id, id: directive_id}}

  @impl true
  def list_mental_models(_ctx, bank_id, params, _opts),
    do: {:ok, %{op: :list_mental_models, bank_id: bank_id, params: params}}

  @impl true
  def get_mental_model(_ctx, bank_id, mental_model_id, params, _opts),
    do: {:ok, %{op: :get_mental_model, bank_id: bank_id, id: mental_model_id, params: params}}

  @impl true
  def get_mental_model_history(_ctx, bank_id, mental_model_id, _opts),
    do: {:ok, %{op: :get_mental_model_history, bank_id: bank_id, id: mental_model_id}}

  @impl true
  def create_mental_model(_ctx, bank_id, attrs, _opts),
    do: {:ok, %{op: :create_mental_model, bank_id: bank_id, attrs: attrs}}

  @impl true
  def update_mental_model(_ctx, bank_id, mental_model_id, attrs, _opts),
    do: {:ok, %{op: :update_mental_model, bank_id: bank_id, id: mental_model_id, attrs: attrs}}

  @impl true
  def delete_mental_model(_ctx, bank_id, mental_model_id, _opts),
    do: {:ok, %{op: :delete_mental_model, bank_id: bank_id, id: mental_model_id}}

  @impl true
  def refresh_mental_model(_ctx, bank_id, mental_model_id, _opts),
    do: {:ok, %{op: :refresh_mental_model, bank_id: bank_id, id: mental_model_id}}

  @impl true
  def bank_profile(_ctx, bank_id, _opts), do: {:ok, %{op: :bank_profile, id: bank_id}}

  @impl true
  def list_documents(_ctx, params, _opts), do: {:ok, %{op: :list_documents, params: params}}

  @impl true
  def get_document(_ctx, document_id, _opts), do: {:ok, %{op: :get_document, id: document_id}}

  @impl true
  def list_document_chunks(_ctx, document_id, params, _opts),
    do: {:ok, %{op: :list_document_chunks, id: document_id, params: params}}

  @impl true
  def list_audit_logs(_ctx, params, _opts), do: {:ok, %{op: :list_audit_logs, params: params}}

  @impl true
  def audit_log_stats(_ctx, params, _opts), do: {:ok, %{op: :audit_log_stats, params: params}}

  @impl true
  def update_document(_ctx, bank_id, document_id, attrs, _opts),
    do: {:ok, %{op: :update_document, bank_id: bank_id, id: document_id, attrs: attrs}}

  @impl true
  def delete_document(_ctx, bank_id, document_id, _opts),
    do: {:ok, %{op: :delete_document, bank_id: bank_id, id: document_id}}

  @impl true
  def reprocess_document(_ctx, bank_id, document_id, _opts),
    do: {:ok, %{op: :reprocess_document, bank_id: bank_id, id: document_id}}

  @impl true
  def memory_graph(_ctx, params, _opts), do: {:ok, %{op: :memory_graph, params: params}}

  @impl true
  def get_chunk(_ctx, chunk_id, _opts), do: {:ok, %{op: :get_chunk, id: chunk_id}}

  @impl true
  def list_operations(_ctx, params, _opts), do: {:ok, %{op: :list_operations, params: params}}

  @impl true
  def get_operation(_ctx, operation_id, _opts), do: {:ok, %{op: :get_operation, id: operation_id}}

  @impl true
  def cancel_operation(_ctx, operation_id, _opts),
    do: {:ok, %{op: :cancel_operation, id: operation_id}}

  @impl true
  def retry_operation(_ctx, operation_id, _opts),
    do: {:ok, %{op: :retry_operation, id: operation_id}}

  @impl true
  def recover_consolidation(_ctx, bank_id, _opts),
    do: {:ok, %{op: :recover_consolidation, bank_id: bank_id, retried_count: 0}}

  @impl true
  def clear_observations(_ctx, bank_id, _opts),
    do: {:ok, %{op: :clear_observations, bank_id: bank_id}}

  @impl true
  def clear_memory_observations(_ctx, bank_id, memory_id, _opts),
    do: {:ok, %{op: :clear_memory_observations, bank_id: bank_id, id: memory_id}}
end
