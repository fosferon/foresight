defmodule Foresight.Evals.RankingMetricsTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.RankingMetrics, as: M

  describe "ndcg_at_k/3" do
    test "perfect ordering scores 1.0" do
      rel = %{"a" => 3, "b" => 2, "c" => 1}
      assert M.ndcg_at_k(["a", "b", "c"], rel, 3) == 1.0
    end

    test "reversed ordering scores below 1.0 but above 0" do
      rel = %{"a" => 3, "b" => 2, "c" => 1}
      score = M.ndcg_at_k(["c", "b", "a"], rel, 3)
      assert score > 0.0 and score < 1.0
    end

    test "an irrelevant item ranked first is penalised vs the ideal" do
      rel = %{"good" => 3, "bad" => 0}
      assert M.ndcg_at_k(["bad", "good"], rel, 2) < M.ndcg_at_k(["good", "bad"], rel, 2)
    end

    test "no relevant items floors at 0.0" do
      assert M.ndcg_at_k(["x", "y"], %{}, 2) == 0.0
    end

    test "matches a hand-computed value" do
      # ranked gains [0, 3]: dcg = 0/log2(2) + 3/log2(3) = 3/1.585 = 1.8928
      # ideal gains [3, 0]: idcg = 3/log2(2) + 0 = 3.0
      # ndcg = 1.8928/3 = 0.63093
      assert_in_delta M.ndcg_at_k(["a", "b"], %{"a" => 0, "b" => 3}, 2), 0.63093, 1.0e-5
    end
  end

  describe "mrr/3" do
    test "first result relevant → 1.0" do
      assert M.mrr(["a", "b"], %{"a" => 2}) == 1.0
    end

    test "third result the first relevant → 1/3" do
      assert_in_delta M.mrr(["x", "y", "a"], %{"a" => 1}), 1.0 / 3, 1.0e-9
    end

    test "no relevant result → 0.0" do
      assert M.mrr(["x", "y"], %{"a" => 3}) == 0.0
    end

    test "respects min_relevance threshold" do
      # "a" is only relevance 1; with threshold 2 it does not count
      assert M.mrr(["a", "b"], %{"a" => 1, "b" => 2}, 2) == 0.5
    end
  end

  describe "recall_at_k/4" do
    test "all relevant in top-k → 1.0" do
      assert M.recall_at_k(["a", "b", "c"], %{"a" => 1, "b" => 1}, 3) == 1.0
    end

    test "half the relevant items missed → 0.5" do
      assert M.recall_at_k(["a", "x"], %{"a" => 1, "b" => 1}, 2) == 0.5
    end

    test "nothing relevant → 0.0" do
      assert M.recall_at_k(["a"], %{}, 1) == 0.0
    end
  end

  describe "precision_at_k/4 and mean/1" do
    test "precision counts relevant in top-k over min(k, len)" do
      assert M.precision_at_k(["a", "b", "x"], %{"a" => 1, "b" => 1}, 3) == Float.round(2 / 3, 12)
    end

    test "mean averages per-query scores" do
      assert M.mean([1.0, 0.0, 0.5]) == 0.5
      assert M.mean([]) == 0.0
    end
  end
end
