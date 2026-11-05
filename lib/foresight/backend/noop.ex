defmodule Foresight.Backend.Noop do
  @moduledoc false

  @behaviour Foresight.Backend

  @impl true
  def retain(_ctx, _payload, _opts), do: Foresight.not_implemented("retain")

  @impl true
  def retain_files(_ctx, _payload, _opts), do: Foresight.not_implemented("retain_files")

  @impl true
  def recall(_ctx, _query, _opts), do: Foresight.not_implemented("recall")

  @impl true
  def reflect(_ctx, _query, _opts), do: Foresight.not_implemented("reflect")

  @impl true
  def consolidate(_ctx, _payload, _opts), do: Foresight.not_implemented("consolidate")

  @impl true
  def list_banks(_ctx, _opts), do: Foresight.not_implemented("list_banks")

  @impl true
  def put_bank(_ctx, _bank_id, _attrs, _opts), do: Foresight.not_implemented("put_bank")

  @impl true
  def patch_bank(_ctx, _bank_id, _attrs, _opts), do: Foresight.not_implemented("patch_bank")

  @impl true
  def update_bank_disposition(_ctx, _bank_id, _disposition, _opts),
    do: Foresight.not_implemented("update_bank_disposition")

  @impl true
  def add_bank_background(_ctx, _bank_id, _content, _opts),
    do: Foresight.not_implemented("add_bank_background")

  @impl true
  def delete_bank(_ctx, _bank_id, _opts), do: Foresight.not_implemented("delete_bank")

  @impl true
  def clear_bank_memories(_ctx, _bank_id, _params, _opts),
    do: Foresight.not_implemented("clear_bank_memories")

  @impl true
  def get_bank_config(_ctx, _bank_id, _opts), do: Foresight.not_implemented("get_bank_config")

  @impl true
  def update_bank_config(_ctx, _bank_id, _updates, _opts),
    do: Foresight.not_implemented("update_bank_config")

  @impl true
  def reset_bank_config(_ctx, _bank_id, _opts), do: Foresight.not_implemented("reset_bank_config")

  @impl true
  def create_webhook(_ctx, _bank_id, _attrs, _opts),
    do: Foresight.not_implemented("create_webhook")

  @impl true
  def list_webhooks(_ctx, _bank_id, _opts), do: Foresight.not_implemented("list_webhooks")

  @impl true
  def update_webhook(_ctx, _bank_id, _webhook_id, _attrs, _opts),
    do: Foresight.not_implemented("update_webhook")

  @impl true
  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts),
    do: Foresight.not_implemented("delete_webhook")

  @impl true
  def list_webhook_deliveries(_ctx, _bank_id, _webhook_id, _params, _opts),
    do: Foresight.not_implemented("list_webhook_deliveries")

  @impl true
  def export_bank_template(_ctx, _bank_id, _opts),
    do: Foresight.not_implemented("export_bank_template")

  @impl true
  def import_bank_template(_ctx, _bank_id, _manifest, _opts),
    do: Foresight.not_implemented("import_bank_template")

  @impl true
  def bank_stats(_ctx, _bank_id, _opts), do: Foresight.not_implemented("bank_stats")

  @impl true
  def memories_timeseries(_ctx, _bank_id, _period, _time_field, _opts),
    do: Foresight.not_implemented("memories_timeseries")

  @impl true
  def list_memories(_ctx, _params, _opts), do: Foresight.not_implemented("list_memories")

  @impl true
  def get_memory(_ctx, _memory_id, _opts), do: Foresight.not_implemented("get_memory")

  @impl true
  def get_memory_history(_ctx, _memory_id, _opts),
    do: Foresight.not_implemented("get_memory_history")

  @impl true
  def delete_memory(_ctx, _bank_id, _memory_id, _opts),
    do: Foresight.not_implemented("delete_memory")

  @impl true
  def list_entities(_ctx, _params, _opts), do: Foresight.not_implemented("list_entities")

  @impl true
  def entity_graph(_ctx, _params, _opts), do: Foresight.not_implemented("entity_graph")

  @impl true
  def get_entity(_ctx, _entity_id, _opts), do: Foresight.not_implemented("get_entity")

  @impl true
  def list_tags(_ctx, _params, _opts), do: Foresight.not_implemented("list_tags")

  @impl true
  def list_directives(_ctx, _bank_id, _params, _opts),
    do: Foresight.not_implemented("list_directives")

  @impl true
  def get_directive(_ctx, _bank_id, _directive_id, _opts),
    do: Foresight.not_implemented("get_directive")

  @impl true
  def create_directive(_ctx, _bank_id, _attrs, _opts),
    do: Foresight.not_implemented("create_directive")

  @impl true
  def update_directive(_ctx, _bank_id, _directive_id, _attrs, _opts),
    do: Foresight.not_implemented("update_directive")

  @impl true
  def delete_directive(_ctx, _bank_id, _directive_id, _opts),
    do: Foresight.not_implemented("delete_directive")

  @impl true
  def list_mental_models(_ctx, _bank_id, _params, _opts),
    do: Foresight.not_implemented("list_mental_models")

  @impl true
  def get_mental_model(_ctx, _bank_id, _mental_model_id, _params, _opts),
    do: Foresight.not_implemented("get_mental_model")

  @impl true
  def get_mental_model_history(_ctx, _bank_id, _mental_model_id, _opts),
    do: Foresight.not_implemented("get_mental_model_history")

  @impl true
  def create_mental_model(_ctx, _bank_id, _attrs, _opts),
    do: Foresight.not_implemented("create_mental_model")

  @impl true
  def update_mental_model(_ctx, _bank_id, _mental_model_id, _attrs, _opts),
    do: Foresight.not_implemented("update_mental_model")

  @impl true
  def delete_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: Foresight.not_implemented("delete_mental_model")

  @impl true
  def refresh_mental_model(_ctx, _bank_id, _mental_model_id, _opts),
    do: Foresight.not_implemented("refresh_mental_model")

  @impl true
  def bank_profile(_ctx, _bank_id, _opts), do: Foresight.not_implemented("bank_profile")

  @impl true
  def list_documents(_ctx, _params, _opts), do: Foresight.not_implemented("list_documents")

  @impl true
  def get_document(_ctx, _document_id, _opts), do: Foresight.not_implemented("get_document")

  @impl true
  def list_document_chunks(_ctx, _document_id, _params, _opts),
    do: Foresight.not_implemented("list_document_chunks")

  @impl true
  def list_audit_logs(_ctx, _params, _opts), do: Foresight.not_implemented("list_audit_logs")

  @impl true
  def audit_log_stats(_ctx, _params, _opts), do: Foresight.not_implemented("audit_log_stats")

  @impl true
  def update_document(_ctx, _bank_id, _document_id, _attrs, _opts),
    do: Foresight.not_implemented("update_document")

  @impl true
  def delete_document(_ctx, _bank_id, _document_id, _opts),
    do: Foresight.not_implemented("delete_document")

  @impl true
  def reprocess_document(_ctx, _bank_id, _document_id, _opts),
    do: Foresight.not_implemented("reprocess_document")

  @impl true
  def memory_graph(_ctx, _params, _opts), do: Foresight.not_implemented("memory_graph")

  @impl true
  def get_chunk(_ctx, _chunk_id, _opts), do: Foresight.not_implemented("get_chunk")

  @impl true
  def list_operations(_ctx, _params, _opts), do: Foresight.not_implemented("list_operations")

  @impl true
  def get_operation(_ctx, _operation_id, _opts), do: Foresight.not_implemented("get_operation")

  @impl true
  def cancel_operation(_ctx, _operation_id, _opts),
    do: Foresight.not_implemented("cancel_operation")

  @impl true
  def retry_operation(_ctx, _operation_id, _opts),
    do: Foresight.not_implemented("retry_operation")

  @impl true
  def recover_consolidation(_ctx, _bank_id, _opts),
    do: Foresight.not_implemented("recover_consolidation")

  @impl true
  def clear_observations(_ctx, _bank_id, _opts),
    do: Foresight.not_implemented("clear_observations")

  @impl true
  def clear_memory_observations(_ctx, _bank_id, _memory_id, _opts),
    do: Foresight.not_implemented("clear_memory_observations")
end
