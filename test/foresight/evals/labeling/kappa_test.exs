defmodule Foresight.Evals.Labeling.KappaTest do
  @moduledoc """
  Cohen's kappa between human and llm calibration grades: the gate that
  decides whether the judge's bulk labels are trustworthy enough to train fusion weights against.
  Pure math over the 0..3 graded-relevance scale.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.Kappa

  test "perfect agreement is kappa 1.0 under any weighting" do
    pairs = [{0, 0}, {1, 1}, {2, 2}, {3, 3}]
    assert_in_delta Kappa.weighted(pairs, weighting: :unweighted).kappa, 1.0, 1.0e-9
    assert_in_delta Kappa.weighted(pairs, weighting: :linear).kappa, 1.0, 1.0e-9
    assert_in_delta Kappa.weighted(pairs, weighting: :quadratic).kappa, 1.0, 1.0e-9
  end

  test "matches a hand-computed unweighted Cohen's kappa" do
    # p_o = 3/4; p_e = 0.5 → kappa = (0.75 - 0.5) / (1 - 0.5) = 0.5
    pairs = [{3, 3}, {3, 3}, {0, 0}, {0, 3}]
    %{kappa: kappa, n: n} = Kappa.weighted(pairs, weighting: :unweighted)
    assert n == 4
    assert_in_delta kappa, 0.5, 1.0e-9
  end

  test "quadratic weighting rewards near-misses over far-misses (ordinal awareness)" do
    base = [{0, 0}, {1, 1}, {2, 2}, {3, 3}, {0, 0}, {1, 1}, {2, 2}, {3, 3}]
    near = Kappa.weighted([{0, 1} | base], weighting: :quadratic).kappa
    far = Kappa.weighted([{0, 3} | base], weighting: :quadratic).kappa
    assert near > far
  end

  test "reports n and reflects no pairs as an undefined kappa" do
    assert %{kappa: nil, n: 0} = Kappa.weighted([], weighting: :quadratic)
  end

  test "constant-category agreement is undefined rather than a perfect trust signal" do
    assert %{kappa: nil, n: 4} =
             Kappa.weighted([{3, 3}, {3, 3}, {3, 3}, {3, 3}], weighting: :quadratic)
  end

  test "defaults to quadratic weighting" do
    pairs = [{0, 0}, {1, 2}, {3, 3}]
    assert Kappa.weighted(pairs).weighting == :quadratic
  end
end
