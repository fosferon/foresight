defmodule Foresight.Evals.Labeling.FusionTunerTest do
  @moduledoc """
  Coordinate-ascent. These tests pin the properties that decide whether a
  learned weighting is trustworthy: that ascent can actually find a known-good answer, that
  it never reports a gain it did not make, and that it is deterministic.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.FusionTuner

  defp candidate(ref, ranks, scores),
    do: %{"memory_ref" => ref, "arm_ranks" => ranks, "arm_scores" => scores}

  # Two queries where the KEYWORD arm is the one that finds the relevant memory and the
  # semantic arm actively misleads. A correct ascent should up-weight keyword.
  defp keyword_is_right_pools do
    for q <- ["q1", "q2"] do
      %{
        "query_ref" => q,
        "candidates" => [
          candidate("#{q}_good", %{"semantic" => 3, "keyword" => 1}, %{
            "semantic" => 0.1,
            "keyword" => 0.95
          }),
          candidate("#{q}_bad", %{"semantic" => 1, "keyword" => 3}, %{
            "semantic" => 0.95,
            "keyword" => 0.1
          })
        ]
      }
    end
  end

  defp keyword_is_right_labels do
    %{
      {"q1", "q1_good"} => 3,
      {"q1", "q1_bad"} => 0,
      {"q2", "q2_good"} => 3,
      {"q2", "q2_bad"} => 0
    }
  end

  test "scores a pool against graded labels" do
    result =
      FusionTuner.score(
        keyword_is_right_pools(),
        keyword_is_right_labels(),
        [fusion: :normalized, normalization: :min_max, weights: %{"keyword" => 5.0}],
        k: 10
      )

    assert result.n == 2
    assert result.ndcg == 1.0
    assert result.mrr == 1.0
  end

  test "ascent recovers the arm that actually carries the relevant results" do
    result =
      FusionTuner.ascend(keyword_is_right_pools(), keyword_is_right_labels(),
        fusion_opts: [fusion: :normalized, normalization: :min_max]
      )

    assert result.arms == ["keyword", "semantic"]
    assert result.weights["keyword"] > result.weights["semantic"]
    assert result.learned_ndcg > result.baseline_ndcg
    assert result.delta > 0
  end

  test "is deterministic — same inputs, same weights" do
    run = fn ->
      FusionTuner.ascend(keyword_is_right_pools(), keyword_is_right_labels(),
        fusion_opts: [fusion: :normalized, normalization: :min_max]
      )
    end

    assert run.() == run.()
  end

  test "reports no gain when there is none to find" do
    # Both arms agree perfectly, so no weighting can beat the baseline.
    pools = [
      %{
        "query_ref" => "q1",
        "candidates" => [
          candidate("good", %{"semantic" => 1, "keyword" => 1}, %{
            "semantic" => 0.9,
            "keyword" => 0.9
          }),
          candidate("bad", %{"semantic" => 2, "keyword" => 2}, %{
            "semantic" => 0.1,
            "keyword" => 0.1
          })
        ]
      }
    ]

    result =
      FusionTuner.ascend(pools, %{{"q1", "good"} => 3, {"q1", "bad"} => 0},
        fusion_opts: [fusion: :normalized, normalization: :min_max]
      )

    assert result.delta == 0.0
    assert result.rounds == 0
  end

  test "ascending under :rrf is honestly flat, because weights are inert there" do
    result =
      FusionTuner.ascend(keyword_is_right_pools(), keyword_is_right_labels(),
        fusion_opts: [fusion: :rrf]
      )

    # Must NOT claim a learned improvement it cannot have made.
    assert result.delta == 0.0
  end

  test "skips unlabelled queries instead of scoring them as misses" do
    pools =
      keyword_is_right_pools() ++
        [
          %{
            "query_ref" => "unlabelled",
            "candidates" => [candidate("x", %{"semantic" => 1}, %{})]
          }
        ]

    result =
      FusionTuner.score(pools, keyword_is_right_labels(), [fusion: :normalized], k: 10)

    # n counts scored queries only — otherwise label coverage, not ranking quality, moves
    # the metric.
    assert result.n == 2
  end
end
