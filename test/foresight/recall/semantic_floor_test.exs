defmodule Foresight.Recall.SemanticFloorTest do
  use ExUnit.Case, async: true

  alias Foresight.Recall.SemanticFloor

  test "defaults to 0.3 when the bank sets nothing" do
    assert SemanticFloor.value(%{}) == 0.3
    assert SemanticFloor.value(%{"recall_semantic_floor" => nil}) == 0.3
    assert SemanticFloor.default() == 0.3
  end

  test "honours a numeric or numeric-string bank override inside [0, 1]" do
    assert SemanticFloor.value(%{"recall_semantic_floor" => 0.45}) == 0.45
    assert SemanticFloor.value(%{"recall_semantic_floor" => 1}) == 1.0
    assert SemanticFloor.value(%{"recall_semantic_floor" => 0}) == 0.0
    assert SemanticFloor.value(%{"recall_semantic_floor" => "0.5"}) == 0.5
    assert SemanticFloor.value(%{"recall_semantic_floor" => " 0.6 "}) == 0.6
  end

  test "falls back to the default on out-of-range or malformed values" do
    assert SemanticFloor.value(%{"recall_semantic_floor" => 1.5}) == 0.3
    assert SemanticFloor.value(%{"recall_semantic_floor" => -0.1}) == 0.3
    assert SemanticFloor.value(%{"recall_semantic_floor" => "high"}) == 0.3
    assert SemanticFloor.value(%{"recall_semantic_floor" => "0.5abc"}) == 0.3
    assert SemanticFloor.value(%{"recall_semantic_floor" => %{}}) == 0.3
    assert SemanticFloor.value(nil) == 0.3
  end
end
