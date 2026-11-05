defmodule Foresight.MCP.StreamableHTTPTest do
  use ExUnit.Case, async: false

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

    # A second face with lenient_session on, so the strict default and the opt-in shim are
    # both exercised against the same server.
    {:ok, lenient_bandit} =
      Bandit.start_link(
        plug:
          {Foresight.HTTP.Router,
           config: %{
             auth: %{api_key: nil},
             health: %{checker: Foresight.Health},
             http: %{enabled: true},
             mcp: %{enabled: true, lenient_session: true},
             ml: %{enabled: false},
             oban: %{enabled: false},
             repo: %{enabled: false}
           }},
        scheme: :http,
        port: 0,
        startup_log: false
      )

    {:ok, {_lenient_ip, lenient_port}} = ThousandIsland.listener_info(lenient_bandit)

    on_exit(fn ->
      if Process.alive?(lenient_bandit), do: Process.exit(lenient_bandit, :normal)

      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if Process.alive?(bandit), do: Process.exit(bandit, :normal)
      if Process.alive?(server), do: Process.exit(server, :normal)
      if Process.alive?(registry), do: Process.exit(registry, :normal)
    end)

    {:ok,
     base_url: "http://127.0.0.1:#{port}", lenient_base_url: "http://127.0.0.1:#{lenient_port}"}
  end

  test "streamable HTTP MCP supports initialize and tool calls on a fixed-bank path", %{
    base_url: base_url
  } do
    session_id = initialize_session!(base_url)
    initialized!(base_url, session_id)

    assert {:ok, %Req.Response{status: 200, body: body}} =
             Req.post(
               "#{base_url}/mcp/bank-fixed",
               headers: request_headers(session_id, "application/json"),
               json: %{
                 "jsonrpc" => "2.0",
                 "id" => "recall-1",
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "recall",
                   "arguments" => %{
                     "query" => "hello",
                     "max_tokens" => "25",
                     "trace" => "true"
                   }
                 }
               }
             )

    payload = body["result"]["structuredContent"]

    assert is_map(payload), inspect(body, pretty: true)
    assert payload["bank_id"] == "bank-fixed"
    assert payload["tenant_id"] == "default"
    assert payload["query"]["query"] == "hello"
    assert payload["query"]["max_tokens"] == 25
    assert payload["query"]["trace"] == true
    refute Map.has_key?(payload["query"], "bank_id")
  end

  # Note: the exact shape that consumer sends — bare tools/call, no initialize, no session
  # header. This is what a straight repoint off Python Hindsight produces.
  defp bare_tool_call(base_url) do
    Req.post(
      "#{base_url}/mcp/bank-fixed",
      headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
      json: %{
        "jsonrpc" => "2.0",
        "id" => "bare-1",
        "method" => "tools/call",
        "params" => %{"name" => "recall", "arguments" => %{"query" => "hello"}}
      }
    )
  end

  defp session_id_from(headers) do
    Enum.find_value(headers, fn {key, values} ->
      if String.downcase(key) == "mcp-session-id", do: List.first(values)
    end)
  end

  test "a handshake-less client is rejected by default", %{base_url: base_url} do
    # Pins the strict default: correct MCP behaviour must remain the out-of-box posture.
    assert {:ok, %Req.Response{body: body}} = bare_tool_call(base_url)

    refute get_in(body, ["result", "structuredContent"])

    # The exact error the a downstream consumer spike hit. Asserting the string, not just "an
    # error", so this test fails if the rejection ever becomes something else.
    assert get_in(body, ["error", "data", "message"]) == "Server not initialized"
  end

  test "lenient_session lets a handshake-less client through", %{
    lenient_base_url: base_url
  } do
    assert {:ok, %Req.Response{status: 200, body: body, headers: headers}} =
             bare_tool_call(base_url)

    payload = body["result"]["structuredContent"]

    assert is_map(payload), inspect(body, pretty: true)
    assert payload["bank_id"] == "bank-fixed"
    assert payload["query"]["query"] == "hello"

    # The fabricated session is handed back so a client that CAN keep it, does.
    assert is_binary(session_id_from(headers))
  end

  test "lenient_session does not disturb a client that does handshake", %{
    lenient_base_url: base_url
  } do
    session_id = initialize_session!(base_url)
    initialized!(base_url, session_id)

    assert {:ok, %Req.Response{status: 200, body: body}} =
             Req.post(
               "#{base_url}/mcp/bank-fixed",
               headers: request_headers(session_id, "application/json"),
               json: %{
                 "jsonrpc" => "2.0",
                 "id" => "proper-1",
                 "method" => "tools/call",
                 "params" => %{"name" => "recall", "arguments" => %{"query" => "hello"}}
               }
             )

    assert body["result"]["structuredContent"]["query"]["query"] == "hello"
  end

  defp live_session_count do
    Hermes.Server.Registry.supervisor(:session_supervisor, Foresight.MCP.Server)
    |> DynamicSupervisor.count_children()
    |> Map.get(:active)
  end

  # Raised by a downstream consumer: determine_session_id/3
  # mints a FRESH session id for every header-less request, and Hermes sessions are
  # DynamicSupervisor children with no TTL. A stateless client that never echoes the
  # session header therefore accumulates one supervised process per request, forever.
  test "a header-less client does not accumulate one session per request", %{
    lenient_base_url: base_url
  } do
    before = live_session_count()

    for _ <- 1..25 do
      assert {:ok, %Req.Response{status: 200}} = bare_tool_call(base_url)
    end

    after_calls = live_session_count()

    assert after_calls - before <= 1,
           "25 header-less requests leaked #{after_calls - before} sessions"
  end

  defp initialize_session!(base_url) do
    assert {:ok, %Req.Response{status: 200, headers: headers}} =
             Req.post(
               "#{base_url}/mcp",
               headers: request_headers(nil, "application/json"),
               json: %{
                 "jsonrpc" => "2.0",
                 "id" => "init-1",
                 "method" => "initialize",
                 "params" => %{
                   "protocolVersion" => "2025-03-26",
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "foresight-test-client", "version" => "1.0.0"}
                 }
               }
             )

    session_id =
      Enum.find_value(headers, fn {key, values} ->
        if String.downcase(key) == "mcp-session-id", do: List.first(values)
      end)

    assert is_binary(session_id) and session_id != ""
    session_id
  end

  defp initialized!(base_url, session_id) do
    assert {:ok, %Req.Response{status: 202}} =
             Req.post(
               "#{base_url}/mcp",
               headers: request_headers(session_id, "application/json"),
               json: %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/initialized"
               }
             )
  end

  defp request_headers(nil, accept) do
    [
      {"accept", accept},
      {"content-type", "application/json"}
    ]
  end

  defp request_headers(session_id, accept) do
    [
      {"accept", accept},
      {"content-type", "application/json"},
      {"mcp-session-id", session_id}
    ]
  end
end
