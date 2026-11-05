defmodule Foresight.Prompts.Reflect.V1Test do
  use ExUnit.Case, async: true

  test "build produces a versioned prompt contract and renderable messages" do
    prompt =
      Foresight.Prompts.Reflect.V1.build(
        "What was our latest position after the Oxford debrief on cutover and fallback posture?",
        %{"budget" => "high"},
        %{
          "bank_id" => "fosferon",
          "name" => "Fosferon",
          "mission" => "Remember clearly",
          "disposition" => %{"skepticism" => 3}
        },
        [
          %{
            "content" => "alpha memory",
            "mentioned_at" => "2026-01-02T20:00:00Z",
            "tags" => ["status:corrected", "project:foresight"],
            "expanded_context" => %{"document_text" => "alpha document context"}
          }
        ],
        %{"count" => 1, "freshness" => "up_to_date", "is_stale" => false, "observations" => []}
      )

    assert prompt.contract_version == "reflect.v1"
    assert prompt.bank.name == "Fosferon"

    assert prompt.recalled == [
             %{
               "content" => "alpha memory",
               "mentioned_at" => "2026-01-02T20:00:00Z",
               "tags" => ["status:corrected", "project:foresight"],
               "expanded_context" => %{"document_text" => "alpha document context"}
             }
           ]

    [system, user] = Foresight.Prompts.Reflect.V1.messages(prompt)
    assert system.content =~ "reflect v1"
    assert system.content =~ "prefer corrected, clarified, latest"

    assert user.content =~
             "Query: What was our latest position after the Oxford debrief on cutover and fallback posture?"

    assert user.content =~ "Budget: high"
    assert user.content =~ "alpha memory"
    assert user.content =~ "mentioned_at: 2026-01-02T20:00:00Z"
    assert user.content =~ "tags: status:corrected, project:foresight"
    assert user.content =~ "expanded_context: alpha document context"
    assert user.content =~ "Preserve explicit negations"
    assert user.content =~ "Query focus guidance"
    # Focus guidance must be generic and corpus-agnostic — it must NOT inject the eval's
    # expected named entities or answers into the prompt (the old gamed behaviour).
    assert user.content =~ "Answer the exact question from the strongest grounded evidence"
    refute user.content =~ "Python Hindsight"
    refute user.content =~ "helios-diary cutover gate"
    assert user.content =~ "never return more than 5 memory IDs"
    assert user.content =~ "Return at most 3 IDs"

    assert Foresight.Prompts.Reflect.V1.schema() == %{
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
end
