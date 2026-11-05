defmodule Foresight.EntityExtractors.SimpleTest do
  @moduledoc """
  The regex fallback extractor. Stored facts are assembled as
  `what | When: x | Involving: y` (Foresight.Prompts.Retain.V1.build_fact_text/1), and the
  capitalised labels used to come back as entities of every fact in the bank.
  """
  use ExUnit.Case, async: true

  alias Foresight.EntityExtractors.Simple

  test "does not read the fact assembler's labels as entities" do
    names = Simple.extract("User took the Spanish course | When: 2024-03-01 | Involving: Emma")

    assert "Emma" in names
    assert "Spanish" in names
    refute "When" in names
    refute "Involving" in names
  end

  test "still extracts capitalised tokens, deduplicated" do
    assert Simple.extract("Emma met Emma in Barcelona") == ["Emma", "Barcelona"]
  end
end
