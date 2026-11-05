defmodule Foresight.LLM do
  @moduledoc """
  Seam behaviour for LLM completion.

  Implementations supply structured completion (`complete_structured/4`,
  `complete_json_schema/4`) and, optionally, native tool-calling
  (`complete_with_tools/2` — omit it and the agentic reflect loop falls back to
  the fixed structured pipeline). `supports_tool_calling?/1` detects which kind
  of backend a module is.
  """

  @callback complete_structured(term(), list(term()), module(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback complete_json_schema(term(), list(term()), map(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Tool-calling send used by the agentic reflect loop: given a message list
  and `tools:` in opts, return the raw provider response carrying `tool_calls`.
  Optional — providers/fakes that cannot do native tool-calling omit it, and the
  reflect path falls back to the fixed structured pipeline.
  """
  # Return type is deliberately `term()` rather than LlmCore.LLM.Response.t(): llm_core
  # is optional, and naming its type here would tie this behaviour — which every backend
  # implements — to a dependency a consumer may not have installed.
  @callback complete_with_tools(list(term()), keyword()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks complete_with_tools: 2

  @doc "Whether `llm` implements native tool-calling (drives the agentic-vs-fixed reflect dispatch)."
  @spec supports_tool_calling?(module()) :: boolean()
  def supports_tool_calling?(llm) when is_atom(llm) do
    Code.ensure_loaded?(llm) and function_exported?(llm, :complete_with_tools, 2)
  end
end
