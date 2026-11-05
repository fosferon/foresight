defmodule Foresight.Reflect.CitationSelectionTest do
  @moduledoc """
  The terminal done-tool's declared citations, filtered to what was
  actually retrieved — drops over-citation (retrieved-but-uncited) and
  hallucinations (cited-but-not-retrieved).
  """
  use ExUnit.Case, async: true

  alias Foresight.Reflect.CitationSelection

  defp retrieved(mem \\ [], obs \\ [], mm \\ []),
    do: %{memory: mem, observation: obs, mental_model: mm}

  test "keeps only ids that were both cited and retrieved (drops over-citation + hallucinations)" do
    got =
      CitationSelection.select(
        %{"memory_ids" => ["b", "x"], "observation_ids" => ["o2"], "mental_model_ids" => []},
        retrieved(["a", "b", "c"], ["o1", "o2"], ["m1"])
      )

    # b cited+retrieved -> kept; a/c retrieved-but-uncited -> dropped; x cited-but-not-retrieved -> dropped
    assert got == %{memory: ["b"], observation: ["o2"], mental_model: []}
  end

  test "preserves retrieved order regardless of citation order" do
    got = CitationSelection.select(%{"memory_ids" => ["c", "a"]}, retrieved(["a", "b", "c"]))
    assert got.memory == ["a", "c"]
  end

  test "missing / empty citation keys yield empty tiers (no over-citation fallback)" do
    got = CitationSelection.select(%{}, retrieved(["a", "b"], ["o1"], ["m1"]))
    assert got == %{memory: [], observation: [], mental_model: []}
  end

  test "coerces non-string cited ids and ignores non-list citation values" do
    got =
      CitationSelection.select(
        %{"memory_ids" => [123], "observation_ids" => "nope"},
        retrieved(["123"], ["o1"])
      )

    assert got.memory == ["123"]
    assert got.observation == []
  end
end
