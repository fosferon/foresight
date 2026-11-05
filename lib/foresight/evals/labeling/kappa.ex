defmodule Foresight.Evals.Labeling.Kappa do
  @moduledoc """
  Cohen's kappa between human and llm calibration grades — the trust gate on
  the bulk judge. If the judge doesn't agree well enough with the human gold slice, its
  labels can't be trusted to train fusion weights against (optimizing to a machine's
  biases is the same metric-gaming trap the ranking metrics were built to avoid), so the pipeline gates the full labeling run on this number.

  Grades are the ordinal 0..3 relevance scale, so `:quadratic` weighting (the default)
  penalizes an off-by-3 disagreement 9x more than off-by-1 — the right model for graded
  relevance. `:linear` and `:unweighted` are available for comparison. Pure math.
  """

  @categories 0..3
  @k Enum.count(@categories)

  @type pair :: {non_neg_integer(), non_neg_integer()}
  @type weighting :: :quadratic | :linear | :unweighted
  @type result :: %{kappa: float() | nil, n: non_neg_integer(), weighting: weighting()}

  @spec weighted([pair()], keyword()) :: result()
  def weighted(pairs, opts \\ []) do
    weighting = Keyword.get(opts, :weighting, :quadratic)
    n = length(pairs)

    %{kappa: kappa(pairs, n, weighting), n: n, weighting: weighting}
  end

  defp kappa(_pairs, 0, _weighting), do: nil

  defp kappa(pairs, n, weighting) do
    observed = confusion(pairs)
    {rows, cols} = marginals(observed, n)

    {num, den} =
      for i <- @categories, j <- @categories, reduce: {0.0, 0.0} do
        {num, den} ->
          w = weight(i, j, weighting)
          o = Map.get(observed, {i, j}, 0) / n
          e = rows[i] * cols[j]
          {num + w * o, den + w * e}
      end

    if den == 0.0, do: nil, else: 1.0 - num / den
  end

  defp confusion(pairs) do
    Enum.reduce(pairs, %{}, fn {h, l}, acc -> Map.update(acc, {h, l}, 1, &(&1 + 1)) end)
  end

  defp marginals(observed, n) do
    rows =
      Map.new(@categories, fn i ->
        {i, Enum.sum(for(j <- @categories, do: Map.get(observed, {i, j}, 0))) / n}
      end)

    cols =
      Map.new(@categories, fn j ->
        {j, Enum.sum(for(i <- @categories, do: Map.get(observed, {i, j}, 0))) / n}
      end)

    {rows, cols}
  end

  defp weight(i, j, :unweighted), do: if(i == j, do: 0.0, else: 1.0)
  defp weight(i, j, :linear), do: abs(i - j) / (@k - 1)
  defp weight(i, j, :quadratic), do: :math.pow(i - j, 2) / :math.pow(@k - 1, 2)
end
