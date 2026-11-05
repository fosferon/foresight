defmodule Foresight.Prompts.Reflect.Tools do
  @moduledoc """
  Reflect agent tool definitions — the provider-neutral `LlmToolkit.Tool`
  set the agentic reflect loop exposes to the LLM. Faithful port of Hindsight's
  `engine/reflect/tools_schema.py` (`get_reflect_tools`).

  Hierarchy the agent is steered through (curated → consolidated → raw):
  `search_mental_models` → `search_observations` → `recall`, with `expand` to
  drill a memory up to its chunk/document, and `done` to answer.

  Definitions are pure data; execution is resolved at loop time by the reflect
  tool resolver (tenant-scoped) — see the agentic reflect loop in
  `Foresight.Storage.Ecto`.
  """

  @default_recall_max_tokens 2048
  @default_observations_max_tokens 5000
  @default_mental_model_max_results 5
  @default_max_chunk_tokens 1000

  @doc """
  Build the enabled reflect tools. `enabled` selects which retrieval tiers are
  active (mental models / observations are skipped when a bank has none), mirroring
  Hindsight's conditional `get_reflect_tools`. `done` and `expand` are always present.
  """
  @spec build(keyword()) :: [LlmToolkit.Tool.t()]
  def build(enabled \\ []) do
    mental_models? = Keyword.get(enabled, :mental_models, true)
    observations? = Keyword.get(enabled, :observations, true)
    # `done` is OFF by default: the LlmCore.Agent.Loop terminates on a plain-text
    # answer, so a `done` tool would be dispatched (unhandled) and burn iterations.
    # Only include it if a caller wires a terminal-tool handler.
    done? = Keyword.get(enabled, :done, false)

    [
      mental_models? && search_mental_models(),
      observations? && search_observations(),
      recall(),
      expand(),
      done? && done()
    ]
    |> Enum.filter(& &1)
  end

  @string %{"type" => "string"}
  @reason %{
    "type" => "string",
    "description" => "One sentence on why you are calling this tool now."
  }

  defp search_mental_models do
    tool(
      "search_mental_models",
      "Search user-curated, manually-maintained topic summaries (the highest-trust tier). " <>
        "Consult these first: they are the operator's own durable notes.",
      %{
        "reason" => @reason,
        "query" => Map.put(@string, "description", "What to look up in the mental models."),
        "max_results" => %{
          "type" => "integer",
          "description" => "Max mental models to return.",
          "default" => @default_mental_model_max_results
        }
      },
      ["reason", "query"]
    )
  end

  defp search_observations do
    tool(
      "search_observations",
      "Search auto-consolidated knowledge — observations synthesized from many raw memories at " <>
        "write time. Prefer these over raw recall for stable, aggregated facts; each carries a " <>
        "freshness signal. Fall back to `recall` to verify a stale or surprising observation.",
      %{
        "reason" => @reason,
        "query" => Map.put(@string, "description", "What consolidated knowledge to retrieve."),
        "max_tokens" => %{
          "type" => "integer",
          "description" => "Token budget for returned observations.",
          "default" => @default_observations_max_tokens
        }
      },
      ["reason", "query"]
    )
  end

  defp recall do
    tool(
      "recall",
      "Retrieve raw ground-truth memories (individual experienced/world facts) via semantic + " <>
        "keyword + graph retrieval. The source of truth — use to verify observations or when no " <>
        "consolidated knowledge covers the question.",
      %{
        "reason" => @reason,
        "query" => Map.put(@string, "description", "What raw facts to retrieve."),
        "max_tokens" => %{
          "type" => "integer",
          "description" => "Token budget for returned memories.",
          "default" => @default_recall_max_tokens
        },
        "max_chunk_tokens" => %{
          "type" => "integer",
          "description" => "Token budget for each memory's source chunk.",
          "default" => @default_max_chunk_tokens
        }
      },
      ["reason", "query"]
    )
  end

  defp expand do
    tool(
      "expand",
      "Drill specific memories up the hierarchy: memory → source chunk → full document. Use when a " <>
        "recalled fact is truncated or you need its surrounding context to answer precisely.",
      %{
        "reason" => @reason,
        "memory_ids" => %{
          "type" => "array",
          "items" => @string,
          "description" => "IDs of previously-retrieved memories to expand."
        },
        "depth" => %{
          "type" => "string",
          "enum" => ["chunk", "document"],
          "description" => "How far to expand: to the source chunk or the full document.",
          "default" => "chunk"
        }
      },
      ["reason", "memory_ids"]
    )
  end

  defp done do
    tool(
      "done",
      "Provide the final answer. Only call this once you have gathered evidence — a `done` with no " <>
        "cited memories/observations is rejected. Cite exactly the IDs you actually used.",
      %{
        "answer" => Map.put(@string, "description", "The final answer, in markdown."),
        "memory_ids" => id_array("Raw memory IDs that support the answer."),
        "mental_model_ids" => id_array("Mental model IDs that support the answer."),
        "observation_ids" => id_array("Observation IDs that support the answer.")
      },
      ["answer"]
    )
  end

  defp id_array(description) do
    %{"type" => "array", "items" => @string, "description" => description}
  end

  defp tool(name, description, properties, required) do
    %LlmToolkit.Tool{
      name: name,
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => properties,
        "required" => required
      },
      metadata: %{"source" => "reflect", "version" => "v1"}
    }
  end
end
