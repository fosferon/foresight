defmodule Foresight.Reflect.MentalModelRankingTest do
  @moduledoc """
  Lexical relevance ranking + limit for search_mental_models — the
  interim before the fix's embedded semantic ranking. Guards that the tool honours
  its query and caps results instead of returning ALL active mental models.
  """
  use ExUnit.Case, async: true

  alias Foresight.Reflect.MentalModelRanking

  defp mm(id, title, text), do: %{external_id: id, title: title, original_text: text}

  test "ranks by query token overlap — the relevant model first" do
    mms = [
      mm("a", "Budget planning", "quarterly spend and runway"),
      mm("b", "Team velocity", "sprint throughput and delivery cadence"),
      mm("c", "Hiring pipeline", "candidate stages and interviews")
    ]

    ranked = MentalModelRanking.rank(mms, "sprint delivery velocity", 3)
    assert hd(ranked).external_id == "b"
  end

  test "respects the limit (stops the 'return ALL mental models' flood)" do
    mms = for i <- 1..10, do: mm("m#{i}", "title #{i}", "shared topic content")
    assert length(MentalModelRanking.rank(mms, "shared topic", 4)) == 4
  end

  test "blank/nil query preserves input order, still limited" do
    mms = [mm("a", "A", "x"), mm("b", "B", "y"), mm("c", "C", "z")]
    assert Enum.map(MentalModelRanking.rank(mms, "", 2), & &1.external_id) == ["a", "b"]
    assert Enum.map(MentalModelRanking.rank(mms, nil, 2), & &1.external_id) == ["a", "b"]
  end

  test "equal-relevance ties keep input (external_id) order" do
    mms = [
      mm("a", "Alpha", "shared context"),
      mm("b", "Beta", "shared context"),
      mm("c", "Gamma", "unrelated matter")
    ]

    # a and b overlap "shared"/"context" equally; c has none.
    ranked = MentalModelRanking.rank(mms, "shared context", 3)
    assert Enum.map(ranked, & &1.external_id) == ["a", "b", "c"]
  end

  test "tolerates string-keyed maps" do
    mms = [%{"external_id" => "a", "title" => "velocity", "original_text" => "sprint cadence"}]
    assert [%{"external_id" => "a"}] = MentalModelRanking.rank(mms, "velocity", 5)
  end
end
