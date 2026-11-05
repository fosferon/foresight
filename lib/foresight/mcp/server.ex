if Code.ensure_loaded?(Hermes.Server) do
  defmodule Foresight.MCP.Server do
    @moduledoc false

    use Hermes.Server,
      name: "Foresight MCP Server",
      version: "0.1.0",
      capabilities: [:tools]

    alias Foresight.Error
    alias Foresight.MCP.Tools
    alias Hermes.Server.Handlers
    alias Hermes.Server.Response

    require Logger

    @impl true
    def init(_client_info, frame) do
      frame =
        Enum.reduce(Tools.definitions(), frame, fn tool, acc ->
          register_tool(acc, tool.name,
            input_schema: tool.input_schema,
            description: tool.description
          )
        end)

      {:ok, frame}
    end

    @impl true
    def handle_request(request, frame) do
      Handlers.handle(request, __MODULE__, frame)
    end

    # Every clause must reply. This process owns all live MCP sessions, so an unmatched
    # return or an encoding failure here would disconnect every connected client over one
    # client's bad call.
    @impl true
    def handle_tool_call(tool_name, params, frame) do
      case Tools.call(tool_name, params) do
        {:ok, payload} ->
          case Jason.encode(payload) do
            {:ok, text} ->
              {:reply, Response.tool() |> Response.text(text) |> Response.structured(payload),
               frame}

            {:error, reason} ->
              {:reply, error_response(:unencodable_result, %{detail: inspect(reason)}), frame}
          end

        {:error, %Error{reason: reason, detail: detail}} ->
          {:reply, error_response(reason, detail), frame}

        other ->
          Logger.warning("mcp tool #{tool_name} returned an unexpected shape: #{inspect(other)}")
          {:reply, error_response(:internal_error, %{result: inspect(other)}), frame}
      end
    end

    defp error_response(reason, detail) do
      Response.tool()
      |> Response.text("Error: #{reason}: #{inspect(detail)}")
      |> Response.structured(%{"error" => to_string(reason), "detail" => detail})
      |> Map.put(:isError, true)
    end
  end
else
  defmodule Foresight.MCP.Server do
    @moduledoc false

    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]}
      }
    end
  end
end
