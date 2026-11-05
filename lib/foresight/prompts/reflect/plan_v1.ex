defmodule Foresight.Prompts.Reflect.Plan.V1 do
  @moduledoc false

  @type prompt :: %{
          required(:query) => String.t(),
          required(:budget) => String.t() | atom(),
          required(:bank) => map(),
          required(:recalled) => list(map()),
          required(:observations) => map(),
          required(:mental_models) => list(map()),
          required(:directives) => list(map()),
          required(:contract_version) => String.t(),
          optional(:evidence_shortfall) => map()
        }

  @spec build(String.t(), map(), map(), list(map()), map(), list(map()), list(map())) :: prompt()
  def build(
        query,
        payload,
        bank_profile,
        recalled_results,
        observations,
        directives,
        mental_models
      )
      when is_binary(query) do
    %{
      query: query,
      budget: Map.get(payload, "budget", "low"),
      bank: %{
        id: bank_profile["bank_id"],
        name: bank_profile["name"],
        mission: bank_profile["mission"],
        disposition: bank_profile["disposition"] || %{}
      },
      recalled: recalled_results,
      observations: observations,
      directives: directives,
      mental_models: mental_models,
      contract_version: "reflect.plan.v1"
    }
  end

  @spec messages(prompt()) :: [map()]
  def messages(
        %{
          query: query,
          budget: budget,
          bank: bank,
          recalled: recalled,
          observations: observations,
          directives: directives,
          mental_models: mental_models
        } = prompt
      ) do
    evidence_shortfall = Map.get(prompt, :evidence_shortfall)

    observation_lines =
      observations
      |> Map.get("observations", [])
      |> Enum.map_join("\n", fn item -> "- #{item["text"] || item[:text] || ""}" end)

    budget_guidance =
      case to_string(budget) do
        "low" ->
          "- Prioritize a quick grounded answer. Only deepen if observations are stale or evidence is clearly thin."

        "high" ->
          "- Explore more thoroughly. If observations are stale or partial, prefer deeper verification before answering."

        _mid ->
          "- Balance speed and completeness. Verify stale or obviously incomplete evidence before answering."
      end

    [
      %{
        role: :system,
        content:
          "You are Foresight reflect planner v1. Decide whether the current grounding is sufficient or whether consolidation would improve the answer."
      },
      %{
        role: :user,
        content: """
        Query: #{query}
        Budget: #{budget}
        Bank name: #{bank[:name] || bank["name"]}
        Mission: #{bank[:mission] || bank["mission"]}
        #{Foresight.Reflect.Disposition.describe(bank[:disposition] || bank["disposition"])}
        Directives:
        #{Enum.map_join(directives, "\n", fn directive -> "- #{Map.get(directive, :name) || Map.get(directive, "name")}: #{Map.get(directive, :content) || Map.get(directive, "content")}" end)}
        Mental models:
        #{Enum.map_join(mental_models, "\n", fn model -> "- #{Map.get(model, "title") || Map.get(model, :title)}: #{Map.get(model, "text") || Map.get(model, :text)}" end)}
        Observation search:
        - count: #{Map.get(observations, "count", 0)}
        - freshness: #{Map.get(observations, "freshness", "unknown")}
        - is_stale: #{Map.get(observations, "is_stale", false)}
        #{observation_lines}
        Recalled memories:
        #{Enum.map_join(recalled, "\n", &render_recalled_item/1)}

        Evidence shortfall:
        #{render_evidence_shortfall(evidence_shortfall)}

        Depth guidance:
        #{budget_guidance}

        Return JSON with:
        - focus_query: refined query for the final answer
        - needs_consolidation: boolean
        - answer_ready: boolean
        - refinement_intent: optional string. Use "memory_source_breadth" when the best next move is a source-linked retry specifically to broaden raw-memory breadth. Use "memory_source_then_memory_breadth" when source-linked verification should be tried first but a raw-memory retry should still follow if source-linked verification stalls. Use "source_family_breadth", "source_lineage_breadth", or "source_provenance_breadth" when the next move should explicitly target that specific source-breadth deficiency.
        - reason: short string
        """
      }
    ]
  end

  @spec schema() :: map()
  def schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["focus_query", "needs_consolidation", "answer_ready"],
      properties: %{
        "focus_query" => %{type: "string"},
        "needs_consolidation" => %{type: "boolean"},
        "answer_ready" => %{type: "boolean"},
        "refinement_intent" => %{
          type: "string",
          enum: [
            "memory_source_breadth",
            "memory_source_then_memory_breadth",
            "source_family_breadth",
            "source_lineage_breadth",
            "source_provenance_breadth"
          ]
        },
        "reason" => %{type: "string"}
      }
    }
  end

  defp render_recalled_item(item) do
    text = item["text"] || item["content"] || item[:text] || item[:content] || ""

    case item["expanded_context"] || item[:expanded_context] do
      %{} = expanded ->
        expanded_text =
          expanded["document_text"] || expanded[:document_text] || expanded["chunk_text"] ||
            expanded[:chunk_text] || ""

        "- #{text}\n  expanded_context: #{expanded_text}"

      _ ->
        "- #{text}"
    end
  end

  defp render_evidence_shortfall(nil), do: "- none"

  defp render_evidence_shortfall(%{} = shortfall) do
    """
    - status: #{Map.get(shortfall, "status", "unknown")}
    - reason: #{Map.get(shortfall, "reason", "unknown")}
    - targeted_breadth_metric: #{Map.get(shortfall, "targeted_breadth_metric", "none")}
    - source_family_count: #{Map.get(shortfall, "used_source_family_count", 0)}/#{Map.get(shortfall, "min_source_family_count", 0)}
    - source_lineage_count: #{Map.get(shortfall, "used_source_lineage_count", 0)}/#{Map.get(shortfall, "min_source_lineage_count", 0)}
    - evidence_family_count: #{Map.get(shortfall, "used_evidence_family_count", 0)}/#{Map.get(shortfall, "min_evidence_family_count", 0)}
    """
    |> String.trim()
  end
end
