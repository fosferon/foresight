defmodule Foresight.Prompts.Reflect.V1 do
  @moduledoc false

  @type prompt :: %{
          required(:query) => String.t(),
          required(:budget) => String.t() | atom(),
          required(:bank) => map(),
          required(:recalled) => list(map()),
          required(:observations) => map(),
          required(:directives) => list(map()),
          required(:mental_models) => list(map()),
          optional(:loop) => map(),
          required(:contract_version) => String.t()
        }

  @spec build(String.t(), map(), map(), list(map()), map(), list(map()), list(map()), map()) ::
          prompt()
  def build(
        query,
        payload,
        bank_profile,
        recalled_results,
        observations,
        directives \\ [],
        mental_models \\ [],
        loop_context \\ %{}
      )
      when is_binary(query) do
    %{
      query: query,
      budget: Map.get(payload, "budget", "mid"),
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
      loop: loop_context,
      contract_version: "reflect.v1"
    }
  end

  @spec messages(prompt()) :: [map()]
  def messages(%{
        query: query,
        budget: budget,
        bank: bank,
        recalled: recalled,
        observations: observations,
        directives: directives,
        mental_models: mental_models,
        loop: loop_context
      }) do
    budget_guidance =
      case to_string(budget) do
        "low" ->
          "- Keep the answer concise and grounded. Prefer existing evidence over extra elaboration."

        "high" ->
          "- Be thorough. Reconcile mental models, observations, and raw memories into a fuller synthesis."

        _mid ->
          "- Be balanced: grounded and reasonably complete without over-expanding."
      end

    intent_guidance =
      query
      |> query_focus_guidance()
      |> Enum.map_join("\n", &("- " <> &1))

    [
      %{
        role: :system,
        content:
          "You are Foresight reflect v1. Use the bank mission, disposition, active directives, and mental models to answer from grounded memory. When recalled memories conflict, prefer corrected, clarified, latest, and explicitly negating evidence over initial, superseded, stale, or wrong statements."
      },
      %{
        role: :user,
        content: """
        Query: #{query}
        Budget: #{budget}
        Bank name: #{bank[:name] || bank["name"]}
        Mission: #{bank[:mission] || bank["mission"]}
        #{Foresight.Reflect.Disposition.describe(bank[:disposition] || bank["disposition"])}
        Active directives:
        #{Enum.map_join(directives, "\n", fn directive -> "- #{Map.get(directive, :name) || Map.get(directive, "name")}: #{Map.get(directive, :content) || Map.get(directive, "content")}" end)}
        Mental models:
        #{Enum.map_join(mental_models, "\n", fn model -> "- #{Map.get(model, "title") || Map.get(model, :title)}: #{Map.get(model, "text") || Map.get(model, :text)}" end)}
        Observation freshness:
        #{inspect(Map.take(observations, ["count", "freshness", "is_stale"]))}
        Planning context:
        #{inspect(loop_context)}
        Recalled memories:
        #{Enum.map_join(recalled, "\n", &render_recalled_item/1)}

        Depth guidance:
        #{budget_guidance}

        Query focus guidance:
        #{intent_guidance}

        Grounding rules:
        - If the recalled evidence conflicts, resolve the conflict explicitly instead of averaging it away.
        - Prefer memories marked by text or tags as corrected, clarified, latest, or active over memories marked as superseded, stale, or wrong.
        - Preserve explicit negations (statements of what did not happen or is not the case) when they are the grounded conclusion.

        Return JSON with:
        - `text`: the answer
        - `directive_compliance`: an object with `status` and `notes`
        - `memory_ids`: retrieved memory IDs actually supporting the answer. Use only the exact IDs shown in the recalled memories section; never copy memory text here. Return only the smallest grounded subset you need, and never return more than 5 memory IDs.
        - `mental_model_ids`: mental model IDs actually supporting the answer. Use only exact IDs. Return at most 3 IDs.
        - `observation_ids`: observation IDs actually supporting the answer. Use only exact IDs. Return at most 3 IDs.
        """
      }
    ]
  end

  @spec schema() :: map()
  def schema do
    %{
      type: "object",
      additionalProperties: false,
      required: [
        "text",
        "directive_compliance",
        "memory_ids",
        "mental_model_ids",
        "observation_ids"
      ],
      properties: %{
        "text" => %{type: "string"},
        "memory_ids" => %{
          type: "array",
          description:
            "Return only the smallest grounded subset needed for the answer, with no more than 5 IDs.",
          items: %{type: "string"}
        },
        "mental_model_ids" => %{
          type: "array",
          description: "Return at most 3 grounded mental model IDs.",
          items: %{type: "string"}
        },
        "observation_ids" => %{
          type: "array",
          description: "Return at most 3 grounded observation IDs.",
          items: %{type: "string"}
        },
        "directive_compliance" => %{
          type: "object",
          additionalProperties: false,
          required: ["status", "notes"],
          properties: %{
            "status" => %{type: "string"},
            "notes" => %{type: "string"}
          }
        }
      }
    }
  end

  defp render_recalled_item(item) do
    id = item["id"] || item[:id] || "unknown"
    text = item["text"] || item["content"] || item[:text] || item[:content] || ""
    mentioned_at = item["mentioned_at"] || item[:mentioned_at]
    tags = item["tags"] || item[:tags] || []

    metadata_lines =
      [
        if(mentioned_at, do: "  mentioned_at: #{mentioned_at}"),
        if(tags != [], do: "  tags: #{Enum.join(tags, ", ")}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    case item["expanded_context"] || item[:expanded_context] do
      %{} = expanded ->
        expanded_text =
          expanded["document_text"] || expanded[:document_text] || expanded["chunk_text"] ||
            expanded[:chunk_text] || ""

        ["- id: #{id}", "  text: #{text}", metadata_lines, "  expanded_context: #{expanded_text}"]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      _ ->
        ["- id: #{id}", "  text: #{text}", metadata_lines]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
    end
  end

  # Generic, corpus-agnostic focus guidance. This deliberately does NOT branch on query
  # strings to inject expected named entities/answers — that primed the model with the
  # eval's target phrasing. The instruction below applies to any query.
  defp query_focus_guidance(_query) do
    [
      "Answer the exact question from the strongest grounded evidence available.",
      "Prefer the most recent, corrected, or clarified evidence over superseded, wrong, or contradicted evidence when they conflict.",
      "Preserve material qualifiers present in that evidence — named entities, dates and temporal windows, numeric thresholds, and explicit negations — and do not generalize them away."
    ]
  end
end
