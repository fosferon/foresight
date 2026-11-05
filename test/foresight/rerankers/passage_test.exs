defmodule Foresight.Rerankers.PassageTest do
  @moduledoc "Faithful reranker passage assembly, matching Hindsight reranking.py."
  use ExUnit.Case, async: true

  alias Foresight.Rerankers.Passage

  test "content only when no context or date" do
    assert Passage.build(%{"content" => "walked the dog"}) == "walked the dog"
  end

  test "prepends context as '<context>: <text>'" do
    assert Passage.build(%{"content" => "walked the dog", "context" => "diary"}) ==
             "diary: walked the dog"
  end

  test "wraps date (from occurred_start) around context+text, readable + iso" do
    passage =
      Passage.build(%{
        "content" => "walked the dog",
        "context" => "diary",
        "occurred_start" => "2022-06-05T00:00:00Z"
      })

    assert passage == "[Date: June 05, 2022 (2022-06-05)] diary: walked the dog"
  end

  test "accepts a date-only occurred_start" do
    assert Passage.build(%{"content" => "x", "occurred_start" => "2022-06-05"}) ==
             "[Date: June 05, 2022 (2022-06-05)] x"
  end

  test "ignores blank context and unparseable/absent date" do
    assert Passage.build(%{"content" => "x", "context" => ""}) == "x"
    assert Passage.build(%{"content" => "x", "occurred_start" => "N/A"}) == "x"
    assert Passage.build(%{"content" => "x"}) == "x"
  end
end
