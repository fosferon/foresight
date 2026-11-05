defmodule Foresight.Recall.RRFTest do
  use ExUnit.Case, async: true

  test "fuses ranked strategy results deterministically with reciprocal rank" do
    alpha = %{"id" => "a", "content" => "alpha", "semantic_score" => 0.91, "graph_score" => 0.88}
    beta = %{"id" => "b", "content" => "beta", "semantic_score" => 0.84, "keyword_score" => 0.8}
    gamma = %{"id" => "c", "content" => "gamma", "semantic_score" => 0.73}

    fused =
      Foresight.Recall.RRF.fuse(%{
        "semantic" => [alpha, beta, gamma],
        "keyword" => [beta, alpha],
        "graph" => [alpha],
        "temporal" => []
      })

    assert Enum.map(fused, & &1["id"]) == ["a", "b", "c"]
    assert hd(fused)["rrf_score"] > Enum.at(fused, 1)["rrf_score"]

    assert hd(fused)["strategy_contributions"] == %{
             "graph" => 1.0 / 61,
             "keyword" => 1.0 / 62,
             "semantic" => 1.0 / 61
           }

    assert hd(fused)["strategy_contribution_details"] == %{
             "graph" => %{
               "rrf_contribution" => Float.round(1.0 / 61, 12),
               "source_rank" => 1,
               "native_score" => 0.88
             },
             "keyword" => %{
               "rrf_contribution" => Float.round(1.0 / 62, 12),
               "source_rank" => 2,
               "native_score" => 0.0
             },
             "semantic" => %{
               "rrf_contribution" => Float.round(1.0 / 61, 12),
               "source_rank" => 1,
               "native_score" => 0.91
             }
           }
  end

  test "supports source_expansion as an explicit fusion lane" do
    beta =
      %{
        "id" => "b",
        "content" => "beta",
        "graph_score" => 0.8,
        "source_expansion_score" => 1.4,
        "graph_source_expansion" => true
      }

    fused =
      Foresight.Recall.RRF.fuse(%{
        "graph" => [beta],
        "source_expansion" => [beta]
      })

    assert [%{"id" => "b"} = first] = fused
    assert Map.has_key?(first["strategy_contributions"], "source_expansion")

    assert first["strategy_contribution_details"]["source_expansion"] == %{
             "rrf_contribution" => Float.round(1.0 / 61, 12),
             "source_rank" => 1,
             "native_score" => 1.4
           }
  end

  # -- calibrated-score fusion ---------------------------------------

  describe "fusion modes" do
    # A tops semantic (1.0) and appears in keyword (0.5); B is bottom of semantic (0.0).
    defp d1_results do
      a = %{"id" => "a", "content" => "a", "semantic_score" => 1.0, "keyword_score" => 0.5}
      b = %{"id" => "b", "content" => "b", "semantic_score" => 0.0}
      %{"semantic" => [a, b], "keyword" => [a]}
    end

    test "defaults to :rrf and adds no normalized fields (byte-compatible baseline)" do
      fused = Foresight.Recall.RRF.fuse(d1_results())
      explicit = Foresight.Recall.RRF.fuse(d1_results(), fusion: :rrf)
      assert fused == explicit
      refute Map.has_key?(hd(fused), "fused_score")
      refute Map.has_key?(hd(fused), "normalized_score")
    end

    test ":normalized sums per-arm min-max scores and applies the convergence bonus" do
      fused = Foresight.Recall.RRF.fuse(d1_results(), fusion: :normalized)
      by_id = Map.new(fused, &{&1["id"], &1})

      # semantic min-max: a=1.0, b=0.0. keyword single: a=1.0.
      # a normalized = 1.0 + 1.0 = 2.0; a in 2 arms → bonus 1.1 → fused 2.2.
      # b normalized = 0.0; 1 arm → fused 0.0.
      assert by_id["a"]["normalized_score"] == 2.0
      assert by_id["a"]["convergence"] == 2
      assert by_id["a"]["fused_score"] == 2.2
      assert by_id["b"]["fused_score"] == 0.0
      assert Enum.map(fused, & &1["id"]) == ["a", "b"]
    end

    test "per-arm weights scale an arm's normalized contribution (the per-bank tuning surface)" do
      fused =
        Foresight.Recall.RRF.fuse(d1_results(),
          fusion: :normalized,
          weights: %{"keyword" => 2.0},
          convergence_bonus: 0.0
        )

      by_id = Map.new(fused, &{&1["id"], &1})
      # a = 1.0(sem) + 2.0*1.0(kw) = 3.0; bonus off → fused 3.0.
      assert by_id["a"]["fused_score"] == 3.0
    end

    test "convergence_bonus: 0.0 disables the multi-arm boost" do
      fused = Foresight.Recall.RRF.fuse(d1_results(), fusion: :normalized, convergence_bonus: 0.0)
      assert Map.new(fused, &{&1["id"], &1})["a"]["fused_score"] == 2.0
    end

    test ":hybrid blends rrf_score with the normalized score" do
      fused = Foresight.Recall.RRF.fuse(d1_results(), fusion: :hybrid, convergence_bonus: 0.0)
      a = Map.new(fused, &{&1["id"], &1})["a"]
      # a rrf = 1/61 (sem r1) + 1/61 (kw r1); hybrid = rrf + 1.0*normalized(2.0).
      assert_in_delta a["fused_score"], 2.0 * (1.0 / 61) + 2.0, 1.0e-9
    end
  end
end
