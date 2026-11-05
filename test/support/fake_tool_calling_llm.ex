defmodule Foresight.TestSupport.FakeToolCallingLLM do
  @moduledoc """
  A fake LLM that drives the agentic reflect loop: it implements
  `complete_with_tools/2` (so `Foresight.LLM.supports_tool_calling?/1` is true and
  reflect takes the agentic path). Scripted behaviour, stateless — keyed on the
  message history the loop accumulates:

    * first call (only system + user messages) → emits a `recall` tool call
    * follow-up call (tool result appended) → emits the final text answer

  Structured/json-schema callbacks delegate to `FakeLLM` so this module can also
  stand in on the fixed reflect path if needed.
  """

  @behaviour Foresight.LLM

  alias LlmCore.LLM.Response

  @answer "AGENTIC_ANSWER: grounded in retrieved memories."

  @impl true
  def complete_with_tools(messages, _opts) do
    if tool_result_present?(messages) do
      {:ok,
       Response.new(
         content: @answer,
         tool_calls: nil,
         usage: %{prompt_tokens: 150, completion_tokens: 30, total_tokens: 180}
       )}
    else
      {:ok,
       Response.new(
         content: nil,
         tool_calls: [
           %LlmToolkit.Tool.Call{
             id: "call_1",
             name: "recall",
             arguments: %{"reason" => "gather supporting facts", "query" => "context"}
           }
         ],
         usage: %{prompt_tokens: 100, completion_tokens: 20, total_tokens: 120}
       )}
    end
  end

  # The loop appends the assistant tool-call message and the tool-result message
  # before the next call, so a history longer than [system, user] means we have
  # already retrieved once.
  defp tool_result_present?(messages), do: length(messages) > 2

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end
