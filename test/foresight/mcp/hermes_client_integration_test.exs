defmodule Foresight.MCP.HermesClientIntegrationTest do
  use ExUnit.Case, async: false

  alias Hermes.Client.Base, as: HermesBase
  alias Hermes.MCP.Response

  defmodule CaptureBackend do
    @behaviour Foresight.Backend

    defdelegate retain(ctx, payload, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate retain_files(ctx, payload, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate reflect(ctx, payload, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate consolidate(ctx, payload, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_banks(ctx, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate put_bank(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate update_bank_disposition(ctx, bank_id, disposition, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate add_bank_background(ctx, bank_id, content, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate patch_bank(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate delete_bank(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate clear_bank_memories(ctx, bank_id, params, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate get_bank_config(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate update_bank_config(ctx, bank_id, updates, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate reset_bank_config(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate create_webhook(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_webhooks(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate update_webhook(ctx, bank_id, webhook_id, attrs, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate delete_webhook(ctx, bank_id, webhook_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate list_webhook_deliveries(ctx, bank_id, webhook_id, params, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate export_bank_template(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate import_bank_template(ctx, bank_id, manifest, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate bank_stats(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_memories(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate get_memory(ctx, memory_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate get_memory_history(ctx, memory_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate delete_memory(ctx, bank_id, memory_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate list_entities(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate entity_graph(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate get_entity(ctx, entity_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_tags(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_directives(ctx, bank_id, params, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate get_directive(ctx, bank_id, directive_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate create_directive(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate update_directive(ctx, bank_id, directive_id, attrs, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate delete_directive(ctx, bank_id, directive_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate list_mental_models(ctx, bank_id, params, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate get_mental_model(ctx, bank_id, mental_model_id, params, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate get_mental_model_history(ctx, bank_id, mental_model_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate create_mental_model(ctx, bank_id, attrs, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate update_mental_model(ctx, bank_id, mental_model_id, attrs, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate delete_mental_model(ctx, bank_id, mental_model_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate refresh_mental_model(ctx, bank_id, mental_model_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate bank_profile(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_documents(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate get_document(ctx, document_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate list_document_chunks(ctx, document_id, params, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate list_audit_logs(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate audit_log_stats(ctx, params, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate memories_timeseries(ctx, bank_id, period, time_field, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate update_document(ctx, bank_id, document_id, attrs, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate delete_document(ctx, bank_id, document_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate reprocess_document(ctx, bank_id, document_id, opts),
      to: Foresight.TestSupport.NoopBackend

    defdelegate memory_graph(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate get_chunk(ctx, chunk_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate list_operations(ctx, params, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate get_operation(ctx, operation_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate cancel_operation(ctx, operation_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate retry_operation(ctx, operation_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate recover_consolidation(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend
    defdelegate clear_observations(ctx, bank_id, opts), to: Foresight.TestSupport.NoopBackend

    defdelegate clear_memory_observations(ctx, bank_id, memory_id, opts),
      to: Foresight.TestSupport.NoopBackend

    def recall(ctx, query, _opts) do
      {:ok, %{"bank_id" => ctx.bank, "tenant_id" => ctx.tenant_id, "query" => query}}
    end
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    Application.put_env(:foresight, :backend, CaptureBackend)

    registry = start_supervised!(Hermes.Server.Registry)

    server =
      start_supervised!(
        {Foresight.MCP.Server, transport: :streamable_http, request_timeout: 5_000}
      )

    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {Foresight.HTTP.Router,
           config: %{
             auth: %{api_key: nil},
             health: %{checker: Foresight.Health},
             http: %{enabled: true},
             mcp: %{enabled: true},
             ml: %{enabled: false},
             oban: %{enabled: false},
             repo: %{enabled: false}
           }},
        scheme: :http,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    client_name = :"foresight_mcp_client_#{System.unique_integer([:positive])}"
    transport_name = :"foresight_mcp_transport_#{System.unique_integer([:positive])}"
    supervisor_name = :"foresight_mcp_client_sup_#{System.unique_integer([:positive])}"

    {:ok, client_sup} =
      start_supervised(
        {Foresight.TestSupport.MCPClient.StreamableHTTPClientSupervisor,
         [
           name: supervisor_name,
           client_name: client_name,
           transport_name: transport_name,
           transport:
             {Foresight.TestSupport.MCPClient.StreamableHTTPTransport,
              [
                base_url: "http://127.0.0.1:#{port}",
                mcp_path: "/mcp/bank-fixed",
                http_options: [receive_timeout: 10_000]
              ]},
           client_info: %{"name" => "foresight-hermes-test", "version" => "1.0.0"},
           capabilities: %{},
           protocol_version: "2025-03-26"
         ]}
      )

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if Process.alive?(bandit), do: Process.exit(bandit, :normal)
      if Process.alive?(client_sup), do: Process.exit(client_sup, :normal)
      if Process.alive?(server), do: Process.exit(server, :normal)
      if Process.alive?(registry), do: Process.exit(registry, :normal)
    end)

    {:ok, client_name: client_name}
  end

  test "Hermes client can list tools and call recall end-to-end", %{client_name: client_name} do
    await_client_ready!(client_name)

    assert {:ok, response} = HermesBase.list_tools(client_name, timeout: 10_000)

    tools =
      response
      |> Response.unwrap()
      |> Map.get("tools", [])

    assert Enum.any?(tools, &(&1["name"] == "recall"))
    assert Enum.any?(tools, &(&1["name"] == "get_memory"))
    assert Enum.any?(tools, &(&1["name"] == "list_tags"))

    assert {:ok, response} =
             HermesBase.call_tool(
               client_name,
               "recall",
               %{"query" => "hello", "max_tokens" => "25", "trace" => "true"},
               timeout: 10_000
             )

    payload =
      response
      |> Response.unwrap()
      |> Map.fetch!("structuredContent")

    assert payload["bank_id"] == "bank-fixed"
    assert payload["tenant_id"] == "default"
    assert payload["query"]["query"] == "hello"
    assert payload["query"]["max_tokens"] == 25
    assert payload["query"]["trace"] == true
  end

  defp await_client_ready!(client_name, attempts \\ 20)

  defp await_client_ready!(_client_name, 0), do: flunk("Hermes MCP client did not initialize")

  defp await_client_ready!(client_name, attempts) do
    case HermesBase.list_tools(client_name, timeout: 1_000) do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(100)
        await_client_ready!(client_name, attempts - 1)
    end
  end
end
