defmodule Foresight.Prompts.Reflect.Structured.V1Test do
  use ExUnit.Case, async: true

  alias Foresight.Prompts.Reflect.Structured.V1

  @schema %{
    "type" => "object",
    "properties" => %{
      "summary" => %{"type" => "string"},
      "grounded" => %{"type" => "boolean"}
    }
  }

  test "system message instructs generic qualifier preservation" do
    [system, _user] =
      V1.messages(
        "What condition mattered before cutting over?",
        "The team cut over only once the recall path proved reliable.",
        @schema
      )

    assert system.content =~ "Preserve the answer's key named entities"
    assert system.content =~ "location anchors"
    assert system.content =~ "numeric or threshold qualifiers"
    assert system.content =~ "explicit negations"
  end

  test "user message echoes the query and answer text verbatim" do
    query = "What condition did the migration care about?"
    answer = "It cut over once the memory path proved reliable enough."

    [_system, user] = V1.messages(query, answer, @schema)

    assert user.content =~ query
    assert user.content =~ answer
    assert user.content =~ "Query focus guidance:"
  end

  test "focus guidance is query-independent — it cannot inject expected answers (anti-gaming)" do
    [_s1, user_a] =
      V1.messages(
        "During the qualification period, what was the fallback purpose of the reference system?",
        "The reference system stayed live as a fallback while the new path was proven.",
        @schema
      )

    [_s2, user_b] =
      V1.messages(
        "Was there a next week calendar cutover date set?",
        "No calendar date was set; the gate was quality.",
        @schema
      )

    guidance_a = extract_focus_guidance(user_a.content)
    guidance_b = extract_focus_guidance(user_b.content)

    # Two materially different queries must receive identical focus guidance. If guidance
    # branched on query strings, it could prime the model with the corpus's expected
    # phrasing — exactly the corpus-string gaming that was removed.
    assert guidance_a == guidance_b
    refute guidance_a == ""
  end

  defp extract_focus_guidance(content) do
    content
    |> String.split("Query focus guidance:")
    |> List.last()
    |> String.split("Return only JSON")
    |> List.first()
    |> String.trim()
  end
end
