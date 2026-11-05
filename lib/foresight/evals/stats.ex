defmodule Foresight.Evals.Stats do
  @moduledoc """
  Statistics for the answer/reflect-judge eval lane.

  The matched-pair eval used to report bare point estimates (e.g. "reflect 0.700,
  fixed 0.700, delta 0.000"), which is underpowered at n=30 (a binomial proportion
  there has a ±0.08 standard error) and treats two coincident point estimates as
  "equal means". These helpers replace that with:

    * `wilson_interval/2` — a 95% Wilson score interval per arm, so 0.700 reads as
      0.700 [~0.52, ~0.83] and the width makes the uncertainty explicit. Wilson is
      used over Wald because it stays inside [0, 1] at the boundaries (0% / 100%).
    * `mcnemar_exact/2` / `paired/1` — because both arms answer the SAME instances,
      the reflect-vs-fixed comparison is PAIRED. Only the discordant pairs carry
      signal; the exact binomial McNemar test gives an honest p-value where naive
      "delta of two independent proportions" would not.
    * `replicate_summary/1` — mean, sample SD, and range across repeated runs, to
      characterize the A/A nondeterminism noise floor (the minimum delta worth
      believing) before attributing a difference to a code change.

  Pure and side-effect-free.
  """

  @z_95 1.959963984540054

  @doc """
  95% Wilson score interval `{lo, hi}` for `successes` out of `n`.

  `n == 0` returns `{0.0, 1.0}` (no information). `opts[:z]` overrides the critical
  value (default 1.96, i.e. 95%).
  """
  @spec wilson_interval(non_neg_integer(), non_neg_integer(), keyword()) :: {float(), float()}
  def wilson_interval(successes, n, opts \\ [])

  def wilson_interval(_successes, 0, _opts), do: {0.0, 1.0}

  def wilson_interval(successes, n, opts) when successes >= 0 and n > 0 and successes <= n do
    z = Keyword.get(opts, :z, @z_95)
    p = successes / n
    z2 = z * z
    denom = 1 + z2 / n
    center = (p + z2 / (2 * n)) / denom
    margin = z / denom * :math.sqrt(p * (1 - p) / n + z2 / (4 * n * n))
    {max(0.0, center - margin), min(1.0, center + margin)}
  end

  @doc """
  Exact two-sided McNemar p-value for discordant paired counts `b` and `c`
  (b = A-correct/B-wrong, c = A-wrong/B-correct). Uses the binomial exact test on
  `min(b, c)` successes out of `b + c` trials at rate 0.5 — no chi-square
  approximation, so it is valid at the small n this eval runs at. `b + c == 0`
  (no discordant pairs) returns `1.0`.
  """
  @spec mcnemar_exact(non_neg_integer(), non_neg_integer()) :: float()
  def mcnemar_exact(b, c) when b >= 0 and c >= 0 do
    nn = b + c

    if nn == 0 do
      1.0
    else
      m = min(b, c)
      tail = Enum.reduce(0..m, 0, fn k, acc -> acc + comb(nn, k) end)
      min(1.0, 2 * tail / :math.pow(2, nn))
    end
  end

  @doc """
  Summarize a list of `{a_correct?, b_correct?}` matched pairs (arm A = e.g. fixed,
  arm B = e.g. reflect). Returns accuracies with Wilson CIs, the discordant counts,
  the paired delta (B − A), and the exact McNemar p-value.
  """
  @spec paired([{boolean(), boolean()}]) :: map()
  def paired(pairs) when is_list(pairs) do
    n = length(pairs)
    a_correct = Enum.count(pairs, fn {a, _b} -> a end)
    b_correct = Enum.count(pairs, fn {_a, b} -> b end)
    a_only = Enum.count(pairs, fn {a, b} -> a and not b end)
    b_only = Enum.count(pairs, fn {a, b} -> b and not a end)

    a_acc = safe_div(a_correct, n)
    b_acc = safe_div(b_correct, n)

    %{
      n: n,
      a_correct: a_correct,
      b_correct: b_correct,
      a_accuracy: a_acc,
      b_accuracy: b_acc,
      a_ci: wilson_interval(a_correct, n),
      b_ci: wilson_interval(b_correct, n),
      a_only: a_only,
      b_only: b_only,
      delta: b_acc - a_acc,
      mcnemar_p: mcnemar_exact(a_only, b_only)
    }
  end

  @doc """
  Mean, sample standard deviation, and range over replicate accuracies — the A/A
  noise floor. A single value yields `sd: 0.0` (no spread estimable).
  """
  @spec replicate_summary([number()]) :: map()
  def replicate_summary(values) when is_list(values) and values != [] do
    n = length(values)
    mean = Enum.sum(values) / n

    sd =
      if n < 2 do
        0.0
      else
        variance =
          Enum.reduce(values, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / (n - 1)

        :math.sqrt(variance)
      end

    %{n: n, mean: mean, sd: sd, min: Enum.min(values), max: Enum.max(values)}
  end

  defp safe_div(_num, 0), do: 0.0
  defp safe_div(num, den), do: num / den

  # Integer binomial coefficient via a product (avoids huge factorials).
  defp comb(_n, 0), do: 1

  defp comb(n, k) when k > 0 and k <= n do
    k = min(k, n - k)
    Enum.reduce(1..k, 1, fn i, acc -> div(acc * (n - k + i), i) end)
  end
end
