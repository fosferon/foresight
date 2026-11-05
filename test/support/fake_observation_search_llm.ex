defmodule Foresight.TestSupport.FakeObservationSearchLLM do
  @moduledoc """
  Drives the agentic reflect loop through the `search_observations`
  tool: the first call emits a `search_observations` tool call; once a tool
  result is present in the history, it emits the final text answer. Used to prove
  the observation tier is reachable via the vector-semantic tool path.

  Structured/json-schema callbacks delegate to `FakeLLM` so this module can also
  stand in on the fixed reflect / consolidation paths if needed.
  """

  @behaviour Foresight.LLM

  alias LlmCore.LLM.Response

  @answer "OBSERVATION_ANSWER: grounded in consolidated observations."

  @impl true
  def complete_with_tools(messages, _opts) do
    if tool_result_present?(messages) do
      {:ok, Response.new(content: @answer, tool_calls: nil)}
    else
      {:ok,
       Response.new(
         content: nil,
         tool_calls: [
           %LlmToolkit.Tool.Call{
             id: "call_obs_1",
             name: "search_observations",
             arguments: %{
               "reason" => "check consolidated knowledge first",
               "query" => "team velocity"
             }
           }
         ]
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
