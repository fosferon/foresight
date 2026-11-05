defmodule Foresight.Evals.Labeling.PoolFusionTest do
  @moduledoc """
  Note: offline re-fusion of a recorded pool. The property that matters is FIDELITY —
  re-fusing a pool must produce the ranking the live fuser would have produced, or the
  weights a tuner learns against it will not transfer to production.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.PoolFusion
  alias Foresight.Recall.RRF

  defp pool(candidates), do: %{"query_ref" => "q1", "candidates" => candidates}

  defp candidate(ref, arm_ranks, arm_scores \\ %{}) do
    %{"memory_ref" => ref, "arm_ranks" => arm_ranks, "arm_scores" => arm_scores}
  end

  test "reconstructs each arm's list in recorded rank order" do
    results =
      PoolFusion.strategy_results(
        pool([
          candidate("a", %{"semantic" => 2}),
          candidate("b", %{"semantic" => 1, "keyword" => 1})
        ])
      )

    assert Enum.map(results["semantic"], & &1["id"]) == ["b", "a"]
    assert Enum.map(results["keyword"], & &1["id"]) == ["b"]
  end

  test "preserves absolute ranks by filling gaps rather than compacting" do
    # Only ranks 1 and 5 survived pooling. Compacting would score the rank-5 candidate as
    # if it were rank 2 — a silent promotion that would bias every downstream metric.
    results = PoolFusion.strategy_results(pool([candidate("far", %{"semantic" => 5})]))

    assert length(results["semantic"]) == 5
    assert List.last(results["semantic"])["id"] == "far"
    assert Enum.take(results["semantic"], 4) |> Enum.all?(&String.starts_with?(&1["id"], "__"))
  end

  test "placeholders never appear in the ranking" do
    ranked = PoolFusion.rank(pool([candidate("far", %{"semantic" => 5})]))

    assert ranked == ["far"]
  end

  test "re-fusing a pool matches what the live fuser produces from the same arms" do
    # The fidelity check: build arm lists directly, fuse them, and confirm the pool
    # round-trip lands on the identical order.
    live = %{
      "semantic" => [%{"id" => "a"}, %{"id" => "b"}, %{"id" => "c"}],
      "keyword" => [%{"id" => "c"}, %{"id" => "a"}]
    }

    expected = live |> RRF.fuse(fusion: :rrf) |> Enum.map(& &1["id"])

    from_pool =
      PoolFusion.rank(
        pool([
          candidate("a", %{"semantic" => 1, "keyword" => 2}),
          candidate("b", %{"semantic" => 2}),
          candidate("c", %{"semantic" => 3, "keyword" => 1})
        ]),
        fusion: :rrf
      )

    assert from_pool == expected
  end

  test "per-arm weights change the ranking under :normalized fusion" do
    candidates = [
      candidate("semantic_favourite", %{"semantic" => 1, "keyword" => 3}, %{
        "semantic" => 0.9,
        "keyword" => 0.1
      }),
      candidate("keyword_favourite", %{"semantic" => 3, "keyword" => 1}, %{
        "semantic" => 0.1,
        "keyword" => 0.9
      })
    ]

    opts = [fusion: :normalized, normalization: :min_max]

    semantic_heavy =
      PoolFusion.rank(pool(candidates), opts ++ [weights: %{"semantic" => 5.0, "keyword" => 0.1}])

    keyword_heavy =
      PoolFusion.rank(pool(candidates), opts ++ [weights: %{"semantic" => 0.1, "keyword" => 5.0}])

    assert hd(semantic_heavy) == "semantic_favourite"
    assert hd(keyword_heavy) == "keyword_favourite"
  end

  test "weights are inert under :rrf, which ranks on reciprocal rank alone" do
    candidates = [
      candidate("a", %{"semantic" => 1}, %{"semantic" => 0.1}),
      candidate("b", %{"keyword" => 1}, %{"keyword" => 0.9})
    ]

    unweighted = PoolFusion.rank(pool(candidates), fusion: :rrf)
    weighted = PoolFusion.rank(pool(candidates), fusion: :rrf, weights: %{"keyword" => 99.0})

    # Documents a real constraint on fusion tuning: learned weights require :normalized or :hybrid.
    assert unweighted == weighted
  end

  test "accepts atom-keyed pools as well as the JSON string form" do
    ranked =
      PoolFusion.rank(%{
        candidates: [%{memory_ref: "a", arm_ranks: %{"semantic" => 1}, arm_scores: %{}}]
      })

    assert ranked == ["a"]
  end
end
