defmodule Foresight.Evals.RankingMetrics do
  @moduledoc """
  Pure, deterministic retrieval-quality metrics — the gaming-resistant core of the
  retrieval eval.

  These operate on IDs and graded relevance labels only. They never inspect answer text,
  so they cannot be satisfied by emitting a corpus phrase (the failure mode that let the
  old phrase-matching grader be gamed from inside the ranking code). A system scores well
  here only by ordering the genuinely-relevant memories ahead of the irrelevant ones.

  Relevance labels are non-negative graded gains (e.g. 0 = irrelevant, 1 = related,
  2 = relevant, 3 = ideal). `ranked_ids` is the system's output order (most-relevant
  first); `relevance` maps an id to its graded label (absent ⇒ 0).
  """

  @type id :: term()
  @type relevance :: %{optional(id()) => number()}

  @doc """
  nDCG@k — normalized discounted cumulative gain over the top `k` results.

  DCG uses the standard log2(rank+1) discount. Normalized by the ideal DCG (the same
  labels sorted by descending gain), so 1.0 means "perfect ordering of the top k" and the
  score is comparable across queries with different label distributions. Returns 0.0 when
  there is no attainable gain (no relevant items), which is the correct floor.
  """
  @spec ndcg_at_k([id()], relevance(), pos_integer()) :: float()
  def ndcg_at_k(ranked_ids, relevance, k) when is_list(ranked_ids) and k > 0 do
    gains = ranked_ids |> Enum.take(k) |> Enum.map(&gain(&1, relevance))
    ideal_gains = relevance |> Map.values() |> Enum.sort(:desc) |> Enum.take(k)

    case dcg(ideal_gains) do
      +0.0 -> 0.0
      idcg -> Float.round(dcg(gains) / idcg, 12)
    end
  end

  @doc """
  MRR — reciprocal rank of the first result whose relevance meets `min_relevance`
  (default 1). 0.0 if no such result appears in `ranked_ids`.
  """
  @spec mrr([id()], relevance(), number()) :: float()
  def mrr(ranked_ids, relevance, min_relevance \\ 1) when is_list(ranked_ids) do
    ranked_ids
    |> Enum.with_index(1)
    |> Enum.find(fn {id, _rank} -> gain(id, relevance) >= min_relevance end)
    |> case do
      {_id, rank} -> Float.round(1.0 / rank, 12)
      nil -> 0.0
    end
  end

  @doc """
  Recall@k — fraction of the relevant items (relevance ≥ `min_relevance`) that appear in
  the top `k`. 0.0 when nothing is relevant (nothing to recall).
  """
  @spec recall_at_k([id()], relevance(), pos_integer(), number()) :: float()
  def recall_at_k(ranked_ids, relevance, k, min_relevance \\ 1)
      when is_list(ranked_ids) and k > 0 do
    relevant = relevant_ids(relevance, min_relevance)

    case MapSet.size(relevant) do
      0 ->
        0.0

      total ->
        hit =
          ranked_ids
          |> Enum.take(k)
          |> Enum.count(&MapSet.member?(relevant, &1))

        Float.round(hit / total, 12)
    end
  end

  @doc """
  Precision@k — fraction of the top `k` results that are relevant (≥ `min_relevance`).
  Denominator is `min(k, length(ranked_ids))` so a short result list is not penalised for
  positions it never had.
  """
  @spec precision_at_k([id()], relevance(), pos_integer(), number()) :: float()
  def precision_at_k(ranked_ids, relevance, k, min_relevance \\ 1)
      when is_list(ranked_ids) and k > 0 do
    top = Enum.take(ranked_ids, k)

    case length(top) do
      0 -> 0.0
      denom -> Float.round(Enum.count(top, &(gain(&1, relevance) >= min_relevance)) / denom, 12)
    end
  end

  @doc """
  Aggregate a metric across many queries by simple mean. Each element of `per_query` is a
  float; returns 0.0 for an empty list.
  """
  @spec mean([number()]) :: float()
  def mean([]), do: 0.0
  def mean(values), do: Float.round(Enum.sum(values) / length(values), 12)

  defp dcg(gains) do
    gains
    |> Enum.with_index(1)
    |> Enum.reduce(0.0, fn {gain, rank}, acc ->
      acc + gain / :math.log2(rank + 1)
    end)
  end

  defp gain(id, relevance), do: max(Map.get(relevance, id, 0), 0)

  defp relevant_ids(relevance, min_relevance) do
    for {id, rel} <- relevance, rel >= min_relevance, into: MapSet.new(), do: id
  end
end
