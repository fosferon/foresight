defmodule Foresight.TestSupport.MCPClient.StreamableHTTPTransport do
  @moduledoc false

  @behaviour Hermes.Transport.Behaviour

  use GenServer

  alias Hermes.SSE
  alias Hermes.SSE.Event

  @default_timeout 15_000
  @build_option_keys [:unix_socket, :pool_tag]
  @request_option_keys [:connect_timeout, :pool_timeout, :receive_timeout, :request_timeout]

  @impl Hermes.Transport.Behaviour
  def supported_protocol_versions, do: ["2025-03-26", "2025-06-18"]

  @impl Hermes.Transport.Behaviour
  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Hermes.Transport.Behaviour
  def send_message(pid, message, opts \\ []) when is_binary(message) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    GenServer.call(pid, {:send, message, opts}, timeout)
  end

  @impl Hermes.Transport.Behaviour
  def shutdown(pid) do
    GenServer.cast(pid, :close_connection)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      mcp_url: build_mcp_url(Keyword.fetch!(opts, :base_url), Keyword.get(opts, :mcp_path, "/")),
      headers: Keyword.get(opts, :headers, %{}),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      http_options: Keyword.get(opts, :http_options, []),
      session_id: nil,
      enable_sse: Keyword.get(opts, :enable_sse, false),
      sse_task: nil,
      last_event_id: nil,
      active_request: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    GenServer.cast(state.client, :initialize)
    {:noreply, maybe_start_sse_connection(state)}
  end

  @impl GenServer
  def handle_call({:send, message, opts}, _from, state) do
    additional_headers = Keyword.get(opts, :headers)
    new_state = %{state | active_request: self()}

    case send_http_request(new_state, message, additional_headers) do
      {:ok, response} ->
        handle_response(response, new_state)

      {:error, {:http_error, 404, _body}} when not is_nil(state.session_id) ->
        {:reply, {:error, :session_expired}, %{new_state | session_id: nil, active_request: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{new_state | active_request: nil}}
    end
  end

  @impl GenServer
  def handle_cast(:close_connection, state) do
    if state.sse_task, do: Task.shutdown(state.sse_task, :brutal_kill)
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:sse_event, event}, state), do: {:noreply, handle_sse_event(event, state)}

  def handle_info({:sse_response_event, event}, state),
    do: {:noreply, handle_sse_event(event, state)}

  def handle_info(:sse_response_complete, state) do
    {:noreply, %{state | active_request: nil}}
  end

  def handle_info({:sse_response_error, _reason}, state) do
    {:noreply, %{state | active_request: nil}}
  end

  def handle_info({:sse_closed, pid, :not_supported}, %{sse_task: %Task{pid: pid}} = state) do
    {:noreply, %{state | sse_task: nil}}
  end

  def handle_info({:sse_closed, pid, _reason}, %{sse_task: %Task{pid: pid}} = state) do
    {:noreply, maybe_start_sse_connection(%{state | sse_task: nil})}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{sse_task: %Task{ref: ref, pid: pid}} = state
      ) do
    {:noreply, maybe_start_sse_connection(%{state | sse_task: nil})}
  end

  def handle_info({ref, _result}, %{sse_task: %Task{ref: ref}} = state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.sse_task, do: Task.shutdown(state.sse_task, :brutal_kill)
    if state.session_id, do: delete_session(state)
    :ok
  end

  def sanitize_finch_build_options(opts), do: Keyword.take(opts || [], @build_option_keys)
  def sanitize_finch_request_options(opts), do: Keyword.take(opts || [], @request_option_keys)

  defp build_mcp_url(%URI{} = base_url, mcp_path), do: URI.append_path(base_url, mcp_path)
  defp build_mcp_url(base_url, mcp_path), do: base_url |> URI.new!() |> URI.append_path(mcp_path)

  defp send_http_request(state, message, additional_headers) do
    base_headers =
      state.headers
      |> Map.put("accept", "application/json, text/event-stream")
      |> Map.put("content-type", "application/json")
      |> put_session_header(state.session_id)

    with {:ok, headers} <- merge_headers(base_headers, additional_headers),
         {:ok, response} <- post(state, URI.to_string(state.mcp_url), headers, message) do
      case response.status do
        status when status in 200..299 -> {:ok, response}
        _ -> {:error, {:http_error, response.status, response.body}}
      end
    end
  end

  defp merge_headers(base_headers, nil), do: {:ok, base_headers}

  defp merge_headers(base_headers, headers) when is_map(headers) do
    case Enum.find(headers, fn {_key, value} -> not is_binary(value) and not is_nil(value) end) do
      nil -> {:ok, Map.merge(base_headers, headers)}
      {key, value} -> {:error, "invalid header #{key}: #{inspect(value)}"}
    end
  end

  defp merge_headers(_base_headers, headers),
    do: {:error, "invalid headers: expected map, got #{inspect(headers)}"}

  defp post(state, url, headers, message) do
    request =
      Finch.build(
        :post,
        url,
        Map.to_list(headers),
        message,
        sanitize_finch_build_options(state.transport_opts)
      )

    Finch.request(request, Hermes.Finch, sanitize_finch_request_options(state.http_options))
  end

  defp get(state, url, headers) do
    request =
      Finch.build(
        :get,
        url,
        Map.to_list(headers),
        nil,
        sanitize_finch_build_options(state.transport_opts)
      )

    Finch.request(request, Hermes.Finch, sanitize_finch_request_options(state.http_options))
  end

  defp delete(state, url, headers) do
    request =
      Finch.build(
        :delete,
        url,
        Map.to_list(headers),
        nil,
        sanitize_finch_build_options(state.transport_opts)
      )

    Finch.request(request, Hermes.Finch, sanitize_finch_request_options(state.http_options))
  end

  defp handle_response(%Finch.Response{headers: headers, body: body, status: status}, state) do
    new_state = update_session_id(state, headers)

    case {status, get_content_type(headers)} do
      {202, _} ->
        {:reply, :ok, %{new_state | active_request: nil}}

      {_, "application/json"} ->
        forward_to_client(body, new_state)
        {:reply, :ok, %{new_state | active_request: nil}}

      {_, "text/event-stream"} ->
        stream_sse_response(body)
        {:noreply, new_state}

      {_, content_type} ->
        {:reply, {:error, {:unsupported_content_type, content_type}},
         %{new_state | active_request: nil}}
    end
  end

  defp forward_to_client(message, %{client: client}) when is_binary(message) do
    GenServer.cast(client, {:response, message})
  end

  defp stream_sse_response(body) when is_binary(body) do
    parent = self()

    Task.start(fn ->
      try do
        body
        |> SSE.Parser.run()
        |> Enum.each(fn event -> send(parent, {:sse_response_event, event}) end)

        send(parent, :sse_response_complete)
      rescue
        _ -> send(parent, {:sse_response_error, :sse_parse_error})
      end
    end)
  end

  defp handle_sse_event({:error, :halted}, state), do: state

  defp handle_sse_event(%Event{data: data, id: id}, state) do
    new_state = if id, do: %{state | last_event_id: id}, else: state
    forward_to_client(data, new_state)
    new_state
  end

  defp handle_sse_event(_event, state), do: state

  defp put_session_header(headers, nil), do: headers
  defp put_session_header(headers, session_id), do: Map.put(headers, "mcp-session-id", session_id)

  defp update_session_id(state, headers) do
    case get_header(headers, "mcp-session-id") do
      nil -> state
      session_id -> %{state | session_id: session_id}
    end
  end

  defp get_header(headers, name) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == String.downcase(name) end)
    |> case do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get_content_type(headers) do
    headers
    |> get_header("content-type")
    |> case do
      nil -> "application/json"
      value -> value |> String.split(";") |> List.first() |> String.trim()
    end
  end

  defp maybe_start_sse_connection(%{enable_sse: false} = state), do: state
  defp maybe_start_sse_connection(%{enable_sse: true, session_id: nil} = state), do: state
  defp maybe_start_sse_connection(%{enable_sse: true, sse_task: %Task{}} = state), do: state

  defp maybe_start_sse_connection(%{enable_sse: true} = state) do
    parent = self()
    task = Task.async(fn -> run_sse_task(parent, state) end)
    %{state | sse_task: task}
  end

  defp run_sse_task(parent, state) do
    headers =
      %{"accept" => "text/event-stream"}
      |> put_session_header(state.session_id)
      |> put_last_event_id_header(state.last_event_id)

    reason =
      case get(state, URI.to_string(state.mcp_url), headers) do
        {:ok, %Finch.Response{status: 200, headers: resp_headers, body: body}}
        when is_binary(body) ->
          if get_content_type(resp_headers) == "text/event-stream" do
            body
            |> SSE.Parser.run()
            |> Enum.each(fn event -> send(parent, {:sse_event, event}) end)
          end

          :normal

        {:ok, %Finch.Response{status: 405}} ->
          :not_supported

        {:ok, %Finch.Response{status: status}} ->
          {:http_status, status}

        {:error, reason} ->
          {:error, reason}
      end

    send(parent, {:sse_closed, self(), reason})
  end

  defp delete_session(state) do
    headers = put_session_header(%{}, state.session_id)

    case delete(state, URI.to_string(state.mcp_url), headers) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204, 404, 405] -> :ok
      {:ok, %Finch.Response{status: _status}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp put_last_event_id_header(headers, nil), do: headers

  defp put_last_event_id_header(headers, event_id),
    do: Map.put(headers, "last-event-id", event_id)
end
