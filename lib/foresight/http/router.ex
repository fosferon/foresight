defmodule Foresight.HTTP.Router do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.Handlers.BankHandler
  alias Foresight.HTTP.Handlers.ConfigHandler
  alias Foresight.HTTP.Handlers.DiagnosticsHandler
  alias Foresight.HTTP.Handlers.DirectiveHandler
  alias Foresight.HTTP.Handlers.HealthHandler
  alias Foresight.HTTP.Handlers.MemoryHandler
  alias Foresight.HTTP.Handlers.MentalModelHandler
  alias Foresight.HTTP.Handlers.MetricsHandler
  alias Foresight.HTTP.Handlers.MigrationHandler
  alias Foresight.HTTP.Handlers.ReadHandler
  alias Foresight.HTTP.Handlers.TemplateHandler
  alias Foresight.HTTP.Handlers.TenantHandler
  alias Foresight.HTTP.Handlers.VersionHandler
  alias Foresight.HTTP.Handlers.WebhookHandler

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:multipart, :json],
    pass: ["application/json", "multipart/form-data"],
    json_decoder: Jason
  )

  plug(:dispatch)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    started_at = System.monotonic_time()

    conn =
      conn
      |> put_private(:foresight_config, Keyword.fetch!(opts, :config))
      |> super(opts)

    Foresight.Telemetry.emit_http_request_stop(conn, System.monotonic_time() - started_at)

    conn
  end

  get "/health" do
    HealthHandler.show(conn)
  end

  get "/metrics" do
    MetricsHandler.show(conn)
  end

  get "/version" do
    VersionHandler.show(conn)
  end

  get "/_foresight/runtime/request-context/:bank_id" do
    DiagnosticsHandler.request_context(conn, bank_id)
  end

  get "/_foresight/tenants/:tenant_id" do
    TenantHandler.show(conn, tenant_id)
  end

  put "/_foresight/tenants/:tenant_id" do
    TenantHandler.provision(conn, tenant_id)
  end

  post "/_foresight/tenants/:tenant_id/drop" do
    TenantHandler.drop(conn, tenant_id)
  end

  get "/v1/bank-template-schema" do
    TemplateHandler.schema(conn)
  end

  get "/v1/default/banks/:bank_id/export" do
    TemplateHandler.export(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/import" do
    TemplateHandler.import_manifest(conn, bank_id)
  end

  get "/v1/default/banks" do
    BankHandler.list(conn)
  end

  get "/v1/default/banks/:bank_id/stats" do
    BankHandler.stats(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/stats/memories-timeseries" do
    ReadHandler.memories_timeseries(conn, bank_id)
  end

  put "/v1/default/banks/:bank_id" do
    BankHandler.put(conn, bank_id)
  end

  patch "/v1/default/banks/:bank_id" do
    BankHandler.patch(conn, bank_id)
  end

  put "/v1/default/banks/:bank_id/profile" do
    BankHandler.put_profile(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/background" do
    BankHandler.background(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/config" do
    ConfigHandler.show(conn, bank_id)
  end

  patch "/v1/default/banks/:bank_id/config" do
    ConfigHandler.patch(conn, bank_id)
  end

  delete "/v1/default/banks/:bank_id/config" do
    ConfigHandler.delete(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/webhooks" do
    WebhookHandler.create(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/webhooks" do
    WebhookHandler.index(conn, bank_id)
  end

  patch "/v1/default/banks/:bank_id/webhooks/:webhook_id" do
    WebhookHandler.patch(conn, bank_id, webhook_id)
  end

  delete "/v1/default/banks/:bank_id/webhooks/:webhook_id" do
    WebhookHandler.delete(conn, bank_id, webhook_id)
  end

  get "/v1/default/banks/:bank_id/webhooks/:webhook_id/deliveries" do
    WebhookHandler.deliveries(conn, bank_id, webhook_id)
  end

  delete "/v1/default/banks/:bank_id" do
    BankHandler.delete(conn, bank_id)
  end

  delete "/v1/default/banks/:bank_id/memories" do
    BankHandler.clear_memories(conn, bank_id)
  end

  delete "/v1/default/banks/:bank_id/memories/:memory_id" do
    MemoryHandler.delete_memory(conn, bank_id, memory_id)
  end

  post "/v1/default/banks/:bank_id/memories" do
    MemoryHandler.retain(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/files/retain" do
    MemoryHandler.retain_files(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/consolidate" do
    MemoryHandler.consolidate(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/consolidation/recover" do
    MemoryHandler.recover_consolidation(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/memories/recall" do
    MemoryHandler.recall(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/memories/list" do
    ReadHandler.list_memories(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/memories/:memory_id" do
    ReadHandler.get_memory(conn, bank_id, memory_id)
  end

  get "/v1/default/banks/:bank_id/memories/:memory_id/history" do
    ReadHandler.get_memory_history(conn, bank_id, memory_id)
  end

  get "/v1/default/banks/:bank_id/entities" do
    ReadHandler.list_entities(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/entities/graph" do
    ReadHandler.entity_graph(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/entities/:entity_id" do
    ReadHandler.get_entity(conn, bank_id, entity_id)
  end

  post "/v1/default/banks/:bank_id/entities/:entity_id/regenerate" do
    ReadHandler.regenerate_entity(conn, bank_id, entity_id)
  end

  get "/v1/default/banks/:bank_id/tags" do
    ReadHandler.list_tags(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/directives" do
    DirectiveHandler.index(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/directives" do
    DirectiveHandler.create(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/directives/:directive_id" do
    DirectiveHandler.show(conn, bank_id, directive_id)
  end

  patch "/v1/default/banks/:bank_id/directives/:directive_id" do
    DirectiveHandler.patch(conn, bank_id, directive_id)
  end

  delete "/v1/default/banks/:bank_id/directives/:directive_id" do
    DirectiveHandler.delete(conn, bank_id, directive_id)
  end

  get "/v1/default/banks/:bank_id/mental-models" do
    MentalModelHandler.index(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/mental-models" do
    MentalModelHandler.create(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/mental-models/:mental_model_id" do
    MentalModelHandler.show(conn, bank_id, mental_model_id)
  end

  get "/v1/default/banks/:bank_id/mental-models/:mental_model_id/history" do
    MentalModelHandler.history(conn, bank_id, mental_model_id)
  end

  patch "/v1/default/banks/:bank_id/mental-models/:mental_model_id" do
    MentalModelHandler.patch(conn, bank_id, mental_model_id)
  end

  post "/v1/default/banks/:bank_id/mental-models/:mental_model_id/refresh" do
    MentalModelHandler.refresh(conn, bank_id, mental_model_id)
  end

  delete "/v1/default/banks/:bank_id/mental-models/:mental_model_id" do
    MentalModelHandler.delete(conn, bank_id, mental_model_id)
  end

  get "/v1/default/banks/:bank_id/profile" do
    ReadHandler.profile(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/audit-logs/stats" do
    ReadHandler.audit_log_stats(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/audit-logs" do
    ReadHandler.list_audit_logs(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/documents" do
    ReadHandler.list_documents(conn, bank_id)
  end

  match "/v1/default/banks/:bank_id/documents/*document_path" do
    document_path = Enum.join(document_path, "/")

    cond do
      conn.method == "GET" and String.ends_with?(document_path, "/chunks") ->
        document_id = String.trim_trailing(document_path, "/chunks")
        ReadHandler.list_document_chunks(conn, bank_id, document_id)

      conn.method == "POST" and String.ends_with?(document_path, "/reprocess") ->
        document_id = String.trim_trailing(document_path, "/reprocess")
        MemoryHandler.reprocess_document(conn, bank_id, document_id)

      conn.method == "GET" ->
        ReadHandler.get_document(conn, bank_id, document_path)

      conn.method == "PATCH" ->
        MemoryHandler.patch_document(conn, bank_id, document_path)

      conn.method == "DELETE" ->
        MemoryHandler.delete_document(conn, bank_id, document_path)

      true ->
        ErrorTranslator.send_error(conn, Error.new(:not_found))
    end
  end

  get "/v1/default/banks/:bank_id/graph" do
    ReadHandler.memory_graph(conn, bank_id)
  end

  get "/v1/default/chunks/:chunk_id" do
    ReadHandler.get_chunk(conn, chunk_id)
  end

  get "/v1/default/banks/:bank_id/operations" do
    ReadHandler.list_operations(conn, bank_id)
  end

  get "/v1/default/banks/:bank_id/operations/:operation_id" do
    ReadHandler.get_operation(conn, bank_id, operation_id)
  end

  delete "/v1/default/banks/:bank_id/operations/:operation_id" do
    MemoryHandler.cancel_operation(conn, bank_id, operation_id)
  end

  post "/v1/default/banks/:bank_id/operations/:operation_id/retry" do
    MemoryHandler.retry_operation(conn, bank_id, operation_id)
  end

  delete "/v1/default/banks/:bank_id/observations" do
    MemoryHandler.clear_observations(conn, bank_id)
  end

  delete "/v1/default/banks/:bank_id/memories/:memory_id/observations" do
    MemoryHandler.clear_memory_observations(conn, bank_id, memory_id)
  end

  post "/v1/default/banks/:bank_id/migrations" do
    MigrationHandler.migrate(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/migrations/probe" do
    MigrationHandler.probe(conn, bank_id)
  end

  post "/v1/default/banks/:bank_id/reflect" do
    MemoryHandler.reflect(conn, bank_id)
  end

  forward("/mcp",
    to: Foresight.MCP.AcceptPlug,
    init_opts: [server: Foresight.MCP.Server]
  )

  match _ do
    ErrorTranslator.send_error(conn, Error.new(:not_found))
  end
end
