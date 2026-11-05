defmodule Foresight.TestSupport.FakeDoneLLM do
  @moduledoc """
  Agentic LLM that finishes via the terminal `done` tool: instead of
  answering in plain text, it calls `done` with its answer and its selected citation
  ids. Used to exercise llm_core's `terminal_tool` wiring + LLM-selected citation
  filtering. Cites a deliberately-hallucinated id so the test can prove the
  filter-vs-retrieved step is active (it must be dropped).
  """

  @behaviour Foresight.LLM

  alias LlmCore.LLM.Response

  @answer "DONE_TERMINAL_ANSWER"

  def answer, do: @answer

  @impl true
  def complete_with_tools(_messages, _opts) do
    {:ok,
     Response.new(
       content: nil,
       tool_calls: [
         %LlmToolkit.Tool.Call{
           id: "call_done",
           name: "done",
           arguments: %{
             "answer" => @answer,
             "memory_ids" => ["ghost-id-not-retrieved"],
             "observation_ids" => [],
             "mental_model_ids" => []
           }
         }
       ],
       usage: %{prompt_tokens: 42, completion_tokens: 8, total_tokens: 50}
     )}
  end

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end
