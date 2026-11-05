defmodule Foresight.Storage do
  @moduledoc false

  alias Foresight.Backend
  alias Foresight.Context

  @callback retain(Context.t(), map(), keyword()) :: Backend.result()
  @callback recall(Context.t(), map(), keyword()) :: Backend.result()
  @callback reflect(Context.t(), map(), keyword()) :: Backend.result()
  @callback consolidate(Context.t(), map(), keyword()) :: Backend.result()
  @callback list_banks(Context.t(), keyword()) :: Backend.result()
  @callback put_bank(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback patch_bank(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback update_bank_disposition(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback add_bank_background(Context.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
  @callback delete_bank(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback clear_bank_memories(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback get_bank_config(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback update_bank_config(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback reset_bank_config(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback create_webhook(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback list_webhooks(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback update_webhook(Context.t(), String.t(), String.t(), map(), keyword()) ::
              Backend.result()
  @callback delete_webhook(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  @callback list_webhook_deliveries(Context.t(), String.t(), String.t(), map(), keyword()) ::
              Backend.result()
  @callback export_bank_template(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback import_bank_template(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback bank_stats(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback memories_timeseries(Context.t(), String.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
  @callback list_memories(Context.t(), map(), keyword()) :: Backend.result()
  @callback get_memory(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback get_memory_history(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback delete_memory(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  @callback list_entities(Context.t(), map(), keyword()) :: Backend.result()
  @callback entity_graph(Context.t(), map(), keyword()) :: Backend.result()
  @callback get_entity(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback list_tags(Context.t(), map(), keyword()) :: Backend.result()
  @callback list_directives(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback get_directive(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  @callback create_directive(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback update_directive(Context.t(), String.t(), String.t(), map(), keyword()) ::
              Backend.result()
  @callback delete_directive(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  @callback list_mental_models(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback get_mental_model(Context.t(), String.t(), String.t(), map(), keyword()) ::
              Backend.result()
  @callback get_mental_model_history(Context.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
  @callback create_mental_model(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback update_mental_model(Context.t(), String.t(), String.t(), map(), keyword()) ::
              Backend.result()
  @callback delete_mental_model(Context.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
  @callback refresh_mental_model(Context.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
  @callback bank_profile(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback list_documents(Context.t(), map(), keyword()) :: Backend.result()
  @callback get_document(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback list_document_chunks(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  @callback list_audit_logs(Context.t(), map(), keyword()) :: Backend.result()
  @callback audit_log_stats(Context.t(), map(), keyword()) :: Backend.result()
  @callback update_document(Context.t(), String.t(), String.t(), map(), keyword()) ::
              Backend.result()
  @callback delete_document(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  @callback reprocess_document(Context.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
  @callback memory_graph(Context.t(), map(), keyword()) :: Backend.result()
  @callback get_chunk(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback list_operations(Context.t(), map(), keyword()) :: Backend.result()
  @callback get_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback cancel_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback retry_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback recover_consolidation(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback clear_observations(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback clear_memory_observations(Context.t(), String.t(), String.t(), keyword()) ::
              Backend.result()
end
