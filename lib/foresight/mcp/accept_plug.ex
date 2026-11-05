if Code.ensure_loaded?(Hermes.Server.Transport.StreamableHTTP.Plug) do
  defmodule Foresight.MCP.AcceptPlug do
    @moduledoc false

    @behaviour Plug

    import Plug.Conn

    alias Hermes.MCP.Error
    alias Hermes.MCP.ID
    alias Hermes.MCP.Message
    alias Hermes.Server.Transport.StreamableHTTP
    alias Plug.Conn.Unfetched

    require Logger
    require Message

    # Pinned rather than negotiated: with no client declaration to negotiate against, the
    # server has to choose. Matches the version the streamable-HTTP suite handshakes with.
    @lenient_protocol_version "2025-03-26"

    @impl Plug
    def init(opts) do
      # Hermes' own init/1 keeps only {transport, session_header, timeout} and DISCARDS the
      # server module, so there is no handle on the session supervisor. Carried through
      # here because a fabricated session has to be closable.
      opts
      |> Hermes.Server.Transport.StreamableHTTP.Plug.init()
      |> Map.put(:server, Keyword.fetch!(opts, :server))
      |> Map.put(:registry, Keyword.get(opts, :registry, Hermes.Server.Registry))
    end

    @impl Plug
    def call(conn, hermes_opts) do
      cond do
        not mcp_enabled?(conn) ->
          send_not_found(conn)

        conn.method == "POST" ->
          conn
          |> normalize_accept_header()
          |> handle_post(hermes_opts)

        true ->
          conn
          |> normalize_accept_header()
          |> Hermes.Server.Transport.StreamableHTTP.Plug.call(hermes_opts)
      end
    end

    def normalize_accept_header(conn) do
      accept =
        conn
        |> get_req_header("accept")
        |> List.first("")

      cond do
        String.contains?(accept, "text/event-stream") ->
          conn

        String.contains?(accept, "application/json") ->
          put_req_header(conn, "accept", accept <> ", text/event-stream")

        accept == "" or accept == "*/*" ->
          put_req_header(conn, "accept", "application/json, text/event-stream")

        true ->
          put_req_header(conn, "accept", accept <> ", application/json, text/event-stream")
      end
    end

    def inject_fixed_bank_id(message, nil), do: message

    def inject_fixed_bank_id(%{"method" => "tools/call", "params" => params} = message, bank_id)
        when is_map(params) and is_binary(bank_id) do
      arguments =
        params
        |> Map.get("arguments", %{})
        |> Map.put_new("bank_id", bank_id)

      meta =
        params
        |> Map.get("_meta", %{})
        |> Map.put("fixed_bank_id", bank_id)

      put_in(message, ["params"], Map.merge(params, %{"arguments" => arguments, "_meta" => meta}))
    end

    def inject_fixed_bank_id(message, _bank_id), do: message

    defp handle_post(conn, %{transport: transport, session_header: session_header} = opts) do
      with :ok <- validate_accept_header(conn),
           {:ok, body, conn} <- maybe_read_request_body(conn, opts),
           {:ok, [message]} <- maybe_parse_messages(body) do
        session_id = determine_session_id(conn, session_header, message)
        context = build_request_context(conn)
        message = inject_fixed_bank_id(message, fixed_bank_id(conn))

        fabricated? =
          maybe_bootstrap_session(
            conn,
            transport,
            session_id,
            message,
            context,
            session_header,
            opts
          )

        message
        |> process_message(conn, transport, session_id, context, session_header, opts)
        |> close_fabricated_session(fabricated?, session_id, opts)
      else
        {:error, :invalid_accept_header} ->
          send_error(
            conn,
            406,
            "Not Acceptable: Client must accept both application/json and text/event-stream"
          )

        {:error, :invalid_json} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:parse_error, %{message: "Invalid JSON"}),
            nil
          )

        {:error, reason} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:parse_error, %{reason: reason}),
            nil
          )
      end
    end

    defp process_message(message, conn, transport, session_id, context, session_header, opts)
         when is_map(message) do
      if Message.is_request(message) do
        handle_request_with_possible_sse(
          conn,
          transport,
          session_id,
          message,
          context,
          session_header,
          opts
        )
      else
        transport
        |> transport_call({:handle_message, session_id, message, context}, opts[:timeout])
        |> format_notification_response(conn)
      end
    end

    defp handle_request_with_possible_sse(
           conn,
           transport,
           session_id,
           body,
           context,
           session_header,
           opts
         ) do
      if wants_sse?(conn) do
        handle_sse_request(
          conn,
          transport,
          session_id,
          body,
          context,
          session_header,
          opts
        )
      else
        handle_json_request(
          conn,
          transport,
          session_id,
          body,
          context,
          session_header,
          opts
        )
      end
    end

    defp handle_sse_request(conn, transport, session_id, body, context, session_header, opts) do
      case transport_call(
             transport,
             {:handle_message_for_sse, session_id, body, context},
             opts[:timeout]
           ) do
        {:sse, response} ->
          route_sse_response(
            conn,
            transport,
            session_id,
            response,
            body,
            context,
            session_header,
            opts
          )

        {:ok, response} ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, response)

        {:error, error} ->
          handle_request_error(conn, error, body)
      end
    end

    defp handle_json_request(conn, transport, session_id, body, context, session_header, opts) do
      case transport_call(transport, {:handle_message, session_id, body, context}, opts[:timeout]) do
        {:ok, response} ->
          conn
          |> put_resp_content_type("application/json")
          |> maybe_add_session_header(session_header, session_id)
          |> send_resp(200, response)

        {:error, error} ->
          handle_request_error(conn, error, body)
      end
    end

    defp route_sse_response(
           conn,
           transport,
           session_id,
           response,
           body,
           context,
           session_header,
           opts
         ) do
      if handler_pid = StreamableHTTP.get_sse_handler(transport, session_id) do
        send(handler_pid, {:sse_message, response})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(202, "{}")
      else
        establish_sse_for_request(
          conn,
          transport,
          session_id,
          body,
          context,
          session_header,
          opts
        )
      end
    end

    defp establish_sse_for_request(
           conn,
           transport,
           session_id,
           body,
           context,
           session_header,
           opts
         ) do
      case StreamableHTTP.register_sse_handler(transport, session_id) do
        :ok ->
          start_background_request(transport, session_id, body, context, opts)

          conn
          |> put_resp_header(session_header, session_id)
          |> Hermes.SSE.Streaming.prepare_connection()
          |> Hermes.SSE.Streaming.start(transport, session_id,
            on_close: fn ->
              StreamableHTTP.unregister_sse_handler(transport, session_id)
            end
          )

        {:error, reason} ->
          send_jsonrpc_error(
            conn,
            Error.protocol(:internal_error, %{reason: reason}),
            extract_request_id(body)
          )
      end
    end

    defp start_background_request(transport, session_id, body, context, opts) do
      self_pid = self()
      timeout = opts[:timeout]

      Task.start(fn ->
        case transport_call(transport, {:handle_message, session_id, body, context}, timeout) do
          {:ok, response} when is_binary(response) ->
            send(self_pid, {:sse_message, response})

          _ ->
            :ok
        end
      end)
    end

    defp format_notification_response({:ok, _}, conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, "{}")
    end

    defp format_notification_response({:error, %Error{} = error}, conn) do
      send_jsonrpc_error(conn, error, nil)
    end

    defp format_notification_response({:error, reason}, conn) do
      send_jsonrpc_error(
        conn,
        Error.protocol(:internal_error, %{reason: reason}),
        nil
      )
    end

    defp transport_call(transport, message, timeout) do
      GenServer.call(transport, message, timeout || 30_000)
    catch
      :exit, {:timeout, _} ->
        {:error, Error.transport(:timeout, %{elapsed_ms: timeout || 30_000})}
    end

    defp wants_sse?(conn) do
      conn
      |> get_req_header("accept")
      |> List.first("")
      |> String.contains?("text/event-stream")
    end

    defp validate_accept_header(conn) do
      accept_header =
        conn
        |> get_req_header("accept")
        |> List.first("")

      if String.contains?(accept_header, "application/json") and
           String.contains?(accept_header, "text/event-stream") do
        :ok
      else
        {:error, :invalid_accept_header}
      end
    end

    # Clients ported from Python Hindsight POST a bare tools/call: no initialize
    # request, no initialized notification, no session header. Hermes enforces the MCP
    # lifecycle and answers "Server not initialized" — correct protocol behaviour, and the
    # reason a straight repoint fails.
    #
    # This plug already absorbs three other strict-client requirements (Accept rewriting,
    # session-id fabrication, bank_id injection), and determine_session_id/3 above already
    # INVENTS the session for exactly this case. All that was missing was initializing it.
    #
    # OFF BY DEFAULT, deliberately. Driving the handshake means the server fabricates the
    # client's protocolVersion and capabilities and then negotiates against its own
    # invention, so the negotiated capability set becomes fiction. That is a reasonable
    # trade for a compatibility shim an operator has opted into, and a bad default: it
    # would silently paper over genuine client bugs.
    defp maybe_bootstrap_session(
           conn,
           transport,
           session_id,
           message,
           context,
           session_header,
           opts
         ) do
      if lenient_session?(conn) and needs_bootstrap?(conn, session_header, message) do
        Logger.info(
          "mcp lenient_session: fabricating an initialized session #{session_id} for a " <>
            "client that sent no handshake"
        )

        transport_call(
          transport,
          {:handle_message, session_id, initialize_request(), context},
          opts[:timeout]
        )

        transport_call(
          transport,
          {:handle_message, session_id, initialized_notification(), context},
          opts[:timeout]
        )

        true
      else
        false
      end
    end

    # A fabricated session belongs to a single request. Hermes sessions are
    # DynamicSupervisor children with NO TTL, and determine_session_id/3 mints a fresh id
    # for every header-less request — so without this, a stateless client ported off the
    # Python API leaks one supervised process per call, forever. Measured before the fix:
    # 25 requests, 25 sessions, none reclaimed.
    #
    # Skipped for a chunked connection: an SSE stream is still using the session, and its
    # own on_close handler owns the teardown.
    defp close_fabricated_session(conn, false, _session_id, _opts), do: conn

    defp close_fabricated_session(%Plug.Conn{state: :chunked} = conn, true, _session_id, _opts),
      do: conn

    defp close_fabricated_session(conn, true, session_id, opts) do
      registry = Map.get(opts, :registry, Hermes.Server.Registry)

      case Map.get(opts, :server) do
        nil -> :ok
        server -> Hermes.Server.Session.Supervisor.close_session(registry, server, session_id)
      end

      conn
    end

    # Only for a client that supplied NO session header. One that supplies a session id is
    # managing its own lifecycle and must not have a second handshake forced onto it.
    defp needs_bootstrap?(conn, session_header, message) do
      get_req_header(conn, session_header) == [] and not Message.is_initialize(message)
    end

    defp initialize_request do
      %{
        "jsonrpc" => "2.0",
        "id" => ID.generate_request_id(),
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @lenient_protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "foresight-lenient-session", "version" => "1.0.0"}
        }
      }
    end

    defp initialized_notification do
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    end

    defp lenient_session?(conn) do
      conn.private
      |> Map.get(:foresight_config, %{})
      |> get_in([:mcp, :lenient_session]) == true
    end

    defp determine_session_id(conn, session_header, message) do
      if Message.is_initialize(message) do
        ID.generate_session_id()
      else
        case get_req_header(conn, session_header) do
          [session_id] when is_binary(session_id) and session_id != "" -> session_id
          _ -> ID.generate_session_id()
        end
      end
    end

    defp maybe_parse_messages(body) when is_binary(body) do
      case Message.decode(body) do
        {:ok, messages} -> {:ok, messages}
        {:error, _reason} -> {:error, :invalid_json}
      end
    end

    defp maybe_parse_messages(body) when is_map(body) do
      case Message.validate_message(body) do
        {:ok, message} -> {:ok, [message]}
        {:error, _} -> {:error, :invalid_json}
      end
    end

    defp maybe_add_session_header(conn, session_header, session_id) do
      if get_req_header(conn, session_header) == [] do
        put_resp_header(conn, session_header, session_id)
      else
        conn
      end
    end

    defp maybe_read_request_body(%{body_params: %Unfetched{aspect: :body_params}} = conn, %{
           timeout: timeout
         }) do
      case Plug.Conn.read_body(conn, read_timeout: timeout) do
        {:ok, body, conn} -> {:ok, body, conn}
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_read_request_body(%{body_params: body} = conn, _opts), do: {:ok, body, conn}

    defp handle_request_error(conn, %Error{} = error, body) do
      send_jsonrpc_error(conn, error, extract_request_id(body))
    end

    defp handle_request_error(conn, reason, body) do
      send_jsonrpc_error(
        conn,
        Error.protocol(:internal_error, %{reason: reason}),
        extract_request_id(body)
      )
    end

    defp send_error(conn, status, message) do
      data = %{data: %{message: message, http_status: status}}

      mcp_error =
        case status do
          405 -> Error.protocol(:method_not_found, data)
          406 -> Error.protocol(:invalid_request, data)
          _ -> Error.protocol(:internal_error, data)
        end

      {:ok, error_response} = Error.to_json_rpc(mcp_error, ID.generate_error_id())

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, error_response)
    end

    defp send_jsonrpc_error(conn, %Error{} = error, id) do
      error_id = id || ID.generate_error_id()
      {:ok, encoded_error} = Error.to_json_rpc(error, error_id)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, encoded_error)
    end

    defp send_not_found(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end

    defp extract_request_id(%{"id" => request_id}), do: request_id
    defp extract_request_id(_), do: nil

    defp build_request_context(conn) do
      %{
        assigns: conn.assigns,
        type: :http,
        req_headers: conn.req_headers,
        query_params: fetch_query_params_safe(conn),
        remote_ip: conn.remote_ip,
        scheme: conn.scheme,
        host: conn.host,
        port: conn.port,
        request_path: conn.request_path,
        fixed_bank_id: fixed_bank_id(conn)
      }
    end

    defp fetch_query_params_safe(conn) do
      case conn.query_params do
        %Unfetched{} -> nil
        params -> params
      end
    end

    defp fixed_bank_id(conn) do
      case conn.path_info do
        [bank_id | _] when is_binary(bank_id) and bank_id != "" -> bank_id
        _ -> nil
      end
    end

    defp mcp_enabled?(conn) do
      conn.private
      |> Map.get(:foresight_config, %{})
      |> get_in([:mcp, :enabled]) == true
    end
  end
else
  defmodule Foresight.MCP.AcceptPlug do
    @moduledoc false

    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end

    def normalize_accept_header(conn), do: conn
    def inject_fixed_bank_id(message, _bank_id), do: message
  end
end
