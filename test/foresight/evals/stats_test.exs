defmodule Foresight.Evals.StatsTest do
  @moduledoc """
  Unit tests for the eval statistics helpers. Reference values are
  computed from the standard formulas (Wilson score interval; exact/binomial
  McNemar) so a regression here means the math drifted, not the test.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Stats

  describe "wilson_interval/2 (95% score interval)" do
    test "p=0.7, n=10 → the textbook [0.3968, 0.8922]" do
      {lo, hi} = Stats.wilson_interval(7, 10)
      assert_in_delta lo, 0.3968, 1.0e-3
      assert_in_delta hi, 0.8922, 1.0e-3
    end

    test "boundary p=1.0 stays inside [0,1] (unlike Wald): lo≈0.7225, hi=1.0" do
      {lo, hi} = Stats.wilson_interval(10, 10)
      assert_in_delta lo, 0.7225, 1.0e-3
      assert hi <= 1.0
      assert_in_delta hi, 1.0, 1.0e-3
    end

    test "boundary p=0.0: lo≈0.0, hi≈0.2776" do
      {lo, hi} = Stats.wilson_interval(0, 10)
      assert_in_delta lo, 0.0, 1.0e-3
      assert_in_delta hi, 0.2776, 1.0e-3
    end

    test "n=0 → maximal uncertainty [0.0, 1.0]" do
      assert Stats.wilson_interval(0, 0) == {0.0, 1.0}
    end
  end

  describe "mcnemar_exact/2 (two-sided paired significance)" do
    test "b=2, c=8 discordant → exact two-sided p = 0.109375" do
      assert_in_delta Stats.mcnemar_exact(2, 8), 0.109375, 1.0e-6
    end

    test "no discordant pairs → p = 1.0 (no evidence of a difference)" do
      assert Stats.mcnemar_exact(0, 0) == 1.0
    end

    test "balanced discordant → p capped at 1.0" do
      assert Stats.mcnemar_exact(5, 5) == 1.0
    end

    test "all discordant favor one arm → strong evidence (p≈0.00195)" do
      assert_in_delta Stats.mcnemar_exact(0, 10), 0.001953, 1.0e-6
    end
  end

  describe "paired/1 (matched-pair arm comparison)" do
    # arm_a = fixed, arm_b = reflect; each pair is {a_correct?, b_correct?}.
    test "summarizes accuracies, discordant counts, delta, and paired p" do
      # 6 both-correct, 2 fixed-only (b), 1 reflect-only (c), 1 both-wrong; n=10.
      pairs =
        List.duplicate({true, true}, 6) ++
          List.duplicate({true, false}, 2) ++
          [{false, true}] ++ [{false, false}]

      s = Stats.paired(pairs)

      assert s.n == 10
      assert_in_delta s.a_accuracy, 0.8, 1.0e-9
      assert_in_delta s.b_accuracy, 0.7, 1.0e-9
      assert s.a_only == 2
      assert s.b_only == 1
      assert_in_delta s.delta, -0.1, 1.0e-9
      assert_in_delta s.mcnemar_p, Stats.mcnemar_exact(2, 1), 1.0e-9
      # marginal CIs are attached for each arm
      assert match?({_, _}, s.a_ci)
      assert match?({_, _}, s.b_ci)
    end
  end

  describe "replicate_summary/1 (A/A noise floor across runs)" do
    test "mean, sample sd, range over replicate accuracies" do
      s = Stats.replicate_summary([0.70, 0.80, 0.70])
      assert_in_delta s.mean, 0.733333, 1.0e-5
      assert s.min == 0.70
      assert s.max == 0.80
      assert_in_delta s.sd, 0.057735, 1.0e-5
      assert s.n == 3
    end

    test "single replicate → sd 0.0 (no spread estimable)" do
      s = Stats.replicate_summary([0.70])
      assert s.sd == 0.0
      assert s.mean == 0.70
    end
  end
end
