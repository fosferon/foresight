defmodule Foresight.TestSupport.FakeLlmCoreProvider do
  @moduledoc false

  @behaviour LlmCore.LLM.Provider

  alias LlmCore.LLM.Response

  @impl true
  def send(prompt, opts) do
    content =
      case prompt do
        [%{role: :user, content: content} | _rest] -> content
        [_system, %{role: :user, content: content}] -> content
        _ -> inspect(prompt)
      end

    json =
      case Keyword.get(opts, :response_format) do
        {:json_schema, schema} -> Jason.encode!(materialize_schema(schema, content))
        _ -> ~s({"text":"structured: #{escape(content)}"})
      end

    {:ok,
     Response.new(
       content: json,
       provider: :fake,
       model: "fake",
       usage: %{prompt_tokens: 7, completion_tokens: 3, total_tokens: 10},
       metadata: %{request_id: "fake-req-1"}
     )}
  end

  @impl true
  def stream(_prompt, _opts), do: {:error, :not_supported}

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: false,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: ["fake"],
      max_context: 8_192
    }
  end

  @impl true
  def provider_type, do: :api

  defp materialize_schema(%{required: required} = schema, content) when is_list(required) do
    schema
    |> Map.get(:properties, %{})
    |> Map.new(fn {key, property} -> {key, materialize_value(property, content)} end)
    |> then(fn result ->
      Enum.reduce(required, result, fn key, acc ->
        Map.put_new(acc, key, "structured: #{content}")
      end)
    end)
  end

  defp materialize_schema(%{"required" => required} = schema, content) when is_list(required) do
    schema
    |> Map.get("properties", %{})
    |> Map.new(fn {key, property} -> {key, materialize_value(property, content)} end)
    |> then(fn result ->
      Enum.reduce(required, result, fn key, acc ->
        Map.put_new(acc, key, "structured: #{content}")
      end)
    end)
  end

  defp materialize_schema(_schema, content), do: %{"text" => "structured: #{content}"}

  defp materialize_value(%{type: "string"}, content), do: "structured: #{content}"
  defp materialize_value(%{"type" => "string"}, content), do: "structured: #{content}"
  defp materialize_value(%{type: "boolean"}, _content), do: true
  defp materialize_value(%{"type" => "boolean"}, _content), do: true
  defp materialize_value(%{type: "integer"}, _content), do: 1
  defp materialize_value(%{"type" => "integer"}, _content), do: 1
  defp materialize_value(%{type: "number"}, _content), do: 1.0
  defp materialize_value(%{"type" => "number"}, _content), do: 1.0
  defp materialize_value(%{type: "array"}, _content), do: []
  defp materialize_value(%{"type" => "array"}, _content), do: []

  defp materialize_value(%{type: "object"} = schema, content),
    do: materialize_schema(schema, content)

  defp materialize_value(%{"type" => "object"} = schema, content),
    do: materialize_schema(schema, content)

  defp materialize_value(_property, content), do: "structured: #{content}"

  defp escape(content) do
    content
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
  end
end

defmodule Foresight.TestSupport.RaisingLlmCoreProvider do
  @moduledoc false

  @behaviour LlmCore.LLM.Provider

  @impl true
  def send(_prompt, _opts) do
    Access.get(
      "The number of tokens to keep from the initial prompt is greater than the context length. Try to load the model with a larger context length, or provide a shorter input",
      "message",
      nil
    )
  end

  @impl true
  def stream(_prompt, _opts), do: {:error, :not_supported}

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    %{
      streaming: false,
      structured_output: true,
      tool_use: false,
      vision: false,
      models: ["raising"],
      max_context: 8_192
    }
  end

  @impl true
  def provider_type, do: :api
end
