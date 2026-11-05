defmodule Foresight.Prompts.Reflect.Structured.V1 do
  @moduledoc false

  @spec messages(String.t(), String.t(), map()) :: [map()]
  def messages(query, text, response_schema) when is_binary(query) and is_binary(text) do
    query_focus_guidance =
      query
      |> query_focus_guidance()
      |> Enum.map_join("\n", &("- " <> &1))

    [
      %{
        role: :system,
        content:
          "You are Foresight structured-output v1. Convert the grounded answer into JSON that strictly satisfies the supplied schema. Preserve the answer's key named entities, decision terms, temporal qualifiers, location anchors, numeric or threshold qualifiers, and explicit negations. Do not generalize away any material qualifier that appears in the answer text."
      },
      %{
        role: :user,
        content: """
        Query: #{query}
        Answer text: #{text}
        Target schema: #{Jason.encode!(response_schema)}

        If the schema includes a summary field, keep it concise but retain the decisive facts from the answer text, including any material names, dates, and thresholds it contains.
        Query focus guidance:
        #{query_focus_guidance}
        Return only JSON satisfying the target schema.
        """
      }
    ]
  end

  # Generic, corpus-agnostic guidance — no branching on query strings to inject expected
  # entities or answers. Applies to any query.
  defp query_focus_guidance(_query) do
    [
      "Preserve the decisive facts needed to answer this exact query, including any material named entities, dates, thresholds, and explicit negations present in the answer text."
    ]
  end
end
