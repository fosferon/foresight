defmodule Foresight.Rerankers.PassthroughTest do
  use ExUnit.Case, async: true

  test "reseeds rerank scores from RRF rank into the [0.1, 1.0] band" do
    candidates = [
      %{"id" => "c", "rrf_score" => 0.3},
      %{"id" => "a", "rrf_score" => 0.9},
      %{"id" => "b", "rrf_score" => 0.6}
    ]

    assert {:ok, reranked} = Foresight.Rerankers.Passthrough.rerank("alpha", candidates, [])

    assert Enum.map(reranked, & &1["id"]) == ["a", "b", "c"]
    assert Enum.map(reranked, & &1["rerank_score"]) == [1.0, 0.55, 0.1]
  end
end
