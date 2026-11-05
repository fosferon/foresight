defmodule Foresight.Recall.FusionConfigTest do
  @moduledoc """
  Per-bank fusion parameters layered over the global calibrated-fusion config. The critical
  property is that a bank WITHOUT an override resolves to exactly what the global layer
  alone produced, so learned weights are strictly opt-in and no existing bank's recall
  changes when this ships.
  """
  use ExUnit.Case, async: true

  alias Foresight.Recall.FusionConfig

  # A later change moved the default off :rrf/:min_max onto :normalized/:zscore on measured
  # evidence (+0.1009 nDCG@10, 95% CI [0.0597, 0.1476], over 134 labelled queries).
  # Pinning it here deliberately: the default is now a claim backed by a number, so a
  # silent change to it should break a test rather than quietly undo the measurement.
  test "no global and no bank config resolves to the shipped defaults" do
    assert FusionConfig.resolve([], nil) == [
             fusion: :normalized,
             normalization: :zscore,
             weights: %{},
             convergence_bonus: 0.1,
             hybrid_alpha: 1.0
           ]
  end

  test "a bank with no override resolves identically to the global layer alone" do
    global = [mode: :normalized, normalization: :zscore, weights: %{semantic: 2.0}]

    assert FusionConfig.resolve(global, nil) == FusionConfig.resolve(global, %{})
    assert FusionConfig.resolve(global, nil)[:fusion] == :normalized
    assert FusionConfig.resolve(global, nil)[:normalization] == :zscore
  end

  test "bank overrides win over the global layer, key by key" do
    global = [mode: :rrf, normalization: :min_max, convergence_bonus: 0.1]
    bank = %{"mode" => "normalized", "weights" => %{"semantic" => 2.5, "keyword" => 0.5}}

    resolved = FusionConfig.resolve(global, bank)

    assert resolved[:fusion] == :normalized
    assert resolved[:weights] == %{"semantic" => 2.5, "keyword" => 0.5}
    # untouched keys still come from the global layer
    assert resolved[:normalization] == :min_max
    assert resolved[:convergence_bonus] == 0.1
  end

  test "coerces the JSONB round trip: string mode, string normalization, integer weights" do
    bank = %{
      "mode" => "hybrid",
      "normalization" => "zscore",
      "hybrid_alpha" => 2,
      "weights" => %{"graph" => 3}
    }

    resolved = FusionConfig.resolve([], bank)

    assert resolved[:fusion] == :hybrid
    assert resolved[:normalization] == :zscore
    assert resolved[:hybrid_alpha] == 2.0
    assert resolved[:weights] == %{"graph" => 3.0}
  end

  test "atom-keyed weights from app config become the string keys RRF looks up by" do
    assert FusionConfig.resolve([weights: %{semantic: 2.0}], nil)[:weights] == %{
             "semantic" => 2.0
           }
  end

  test "an unrecognised mode falls through instead of crashing or silently switching" do
    global = [mode: :normalized]

    # A typo'd or malicious bank value must not select a different mode, and must not take
    # down recall — it simply does not override.
    assert FusionConfig.resolve(global, %{"mode" => "wieghted"})[:fusion] == :normalized
    assert FusionConfig.resolve(global, %{"mode" => 42})[:fusion] == :normalized

    # Falls through to the GLOBAL layer, not to the built-in default. Asserting against a
    # global that deliberately differs from the default (:min_max vs the shipped :zscore)
    # is what makes this meaningful — if the bad value jumped straight to the default,
    # both would read :zscore and the bug would pass unnoticed.
    assert FusionConfig.resolve([normalization: :min_max], %{"normalization" => "nope"})[
             :normalization
           ] == :min_max

    assert FusionConfig.resolve([], %{"normalization" => "nope"})[:normalization] == :zscore
  end

  test "a non-numeric weight is dropped without discarding the sound ones" do
    bank = %{"weights" => %{"semantic" => 2.0, "keyword" => "bogus", "graph" => "1.5"}}

    assert FusionConfig.resolve([], bank)[:weights] == %{"semantic" => 2.0, "graph" => 1.5}
  end

  test "accepts a map-shaped global layer as well as a keyword list" do
    assert FusionConfig.resolve(%{mode: :hybrid}, nil)[:fusion] == :hybrid
    assert FusionConfig.resolve(%{"mode" => "hybrid"}, nil)[:fusion] == :hybrid
  end
end
