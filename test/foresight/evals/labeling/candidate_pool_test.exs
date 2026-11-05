defmodule Foresight.Evals.Labeling.CandidatePoolTest do
  @moduledoc """
  Pure pooling of pre-fusion arm results into the deduped
  candidate set to be labeled for a query. Operates on the `strategy_items` shape that
  escapes ranked_recall_items/6 (arm_name => ranked item list); no DB, no recall call.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.CandidatePool

  # Mirrors the arm-item shape from memory_unit_to_recall_response/2: string "id",
  # "content"/"context", and metadata carrying the stable "eval_id" label key.
  defp item(id, eval_id, content) do
    %{
      "id" => id,
      "content" => content,
      "context" => "ctx:#{eval_id}",
      "metadata" => %{"eval_id" => eval_id}
    }
  end

  test "unions candidates across arms and dedups a shared memory into one candidate" do
    strategy_items = %{
      "semantic" => [item("u1", "session_a", "a"), item("u2", "session_b", "b")],
      "keyword" => [item("u1", "session_a", "a"), item("u3", "session_c", "c")]
    }

    %{candidates: candidates} = CandidatePool.pool(strategy_items)

    refs = Enum.map(candidates, & &1.memory_ref) |> Enum.sort()
    assert refs == ["session_a", "session_b", "session_c"]

    shared = Enum.find(candidates, &(&1.memory_ref == "session_a"))
    assert Enum.sort(shared.arms) == ["keyword", "semantic"]
    assert shared.memory_id == "u1"
    assert shared.content == "a"
  end

  # Note: RRF fusion is a function of EACH arm's rank for a candidate, so a pool that
  # keeps only the minimum rank cannot be re-fused offline — which is exactly what the
  # fusion tuner's coordinate ascent needs to do to score a candidate weighting without re-running recall.
  test "records every arm's rank, not just the best one" do
    strategy_items = %{
      "semantic" => [item("u9", "s9", "9"), item("u1", "session_a", "a")],
      "keyword" => [item("u1", "session_a", "a")],
      "graph" => [item("u8", "s8", "8"), item("u7", "s7", "7"), item("u1", "session_a", "a")]
    }

    %{candidates: candidates} = CandidatePool.pool(strategy_items)
    shared = Enum.find(candidates, &(&1.memory_ref == "session_a"))

    assert shared.arm_ranks == %{"semantic" => 2, "keyword" => 1, "graph" => 3}
    # best_rank stays the minimum across arms, as before.
    assert shared.best_rank == 1
    assert Enum.sort(shared.arms) == ["graph", "keyword", "semantic"]
  end

  # Per-arm WEIGHTS are consulted only by RRF's :normalized and :hybrid modes, and those
  # normalize each arm's NATIVE score — not its rank. So a pool holding ranks alone cannot
  # reproduce a weighted fusion offline, which is the whole point of recording it.
  test "records each arm's native score alongside its rank" do
    strategy_items = %{
      "semantic" => [Map.put(item("u1", "s1", "a"), "semantic_score", 0.83)],
      "keyword" => [Map.put(item("u1", "s1", "a"), "keyword_score", 0.41)]
    }

    %{candidates: [candidate]} = CandidatePool.pool(strategy_items)

    assert candidate.arm_scores == %{"semantic" => 0.83, "keyword" => 0.41}
  end

  test "a missing native score records as 0.0, matching how the fuser reads it" do
    %{candidates: [candidate]} = CandidatePool.pool(%{"graph" => [item("u1", "s1", "a")]})

    assert candidate.arm_scores == %{"graph" => 0.0}
  end

  test "arm_ranks keeps the best rank when one arm lists a candidate twice" do
    strategy_items = %{
      "semantic" => [item("u1", "session_a", "a"), item("u2", "session_a", "dup")]
    }

    %{candidates: [candidate]} = CandidatePool.pool(strategy_items)

    assert candidate.arm_ranks == %{"semantic" => 1}
  end

  test "keeps only top_k per arm" do
    strategy_items = %{
      "semantic" => [
        item("u1", "s1", "1"),
        item("u2", "s2", "2"),
        item("u3", "s3", "3")
      ]
    }

    %{candidates: candidates} = CandidatePool.pool(strategy_items, top_k: 2)
    refs = Enum.map(candidates, & &1.memory_ref) |> Enum.sort()
    assert refs == ["s1", "s2"]
  end

  test "best_rank is the minimum surfacing rank across arms" do
    strategy_items = %{
      # u1 is 3rd in semantic...
      "semantic" => [item("x", "sx", "x"), item("y", "sy", "y"), item("u1", "session_a", "a")],
      # ...but 1st in keyword
      "keyword" => [item("u1", "session_a", "a")]
    }

    %{candidates: candidates} = CandidatePool.pool(strategy_items)
    shared = Enum.find(candidates, &(&1.memory_ref == "session_a"))
    assert shared.best_rank == 1
  end

  test "drops candidates without a stable eval_id and reports them separately" do
    strategy_items = %{
      "semantic" => [
        item("u1", "session_a", "a"),
        %{"id" => "u_noeval", "content" => "orphan", "metadata" => %{}}
      ]
    }

    %{candidates: candidates, dropped: dropped} = CandidatePool.pool(strategy_items)
    assert Enum.map(candidates, & &1.memory_ref) == ["session_a"]
    assert length(dropped) == 1
    assert hd(dropped)["id"] == "u_noeval"
  end

  test "empty arms yield no candidates" do
    assert %{candidates: [], dropped: []} = CandidatePool.pool(%{})
  end
end
