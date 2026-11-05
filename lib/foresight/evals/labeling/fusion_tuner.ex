defmodule Foresight.Evals.Labeling.FusionTuner do
  @moduledoc """
  Offline coordinate ascent over per-arm fusion weights, scored as mean
  nDCG@k against graded relevance labels.

  This goes beyond Hindsight, which applies one global fusion scheme to every bank; this
  module learns a weighting per bank from that bank's own labelled data.

  Why a retrieval metric rather than end-to-end answer accuracy: the LongMemEval n=30
  answer-judge lane was measured to have hit its sensitivity ceiling (during the consolidation-batching
  calibration a +52% observation gain came out eval-neutral). nDCG over graded labels removes the
  reader and the judge from the measurement entirely, so a fusion change registers as a
  fusion change instead of disappearing into reflect noise.

  Everything here is pure and deterministic: no RNG, no DB, no network. Ascent visits arms
  in a fixed order and takes the first strictly-better value at each step, so the same
  inputs always yield the same weights.

  DISCIPLINE. Ascent must be run on the TRAIN split only, and the resulting weights scored
  once on the held-out split. `ascend/3` has no access to a test set by construction — the
  caller supplies whatever pools it is allowed to fit on.
  """

  alias Foresight.Evals.Labeling.PoolFusion
  alias Foresight.Evals.RankingMetrics

  @default_k 10
  @default_grid [0.0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0]
  @default_max_rounds 5

  @type labels :: %{{String.t(), String.t()} => non_neg_integer()}

  @doc """
  Mean nDCG@k over every query pool, ranked under `fusion_opts`.

  Queries with no labelled candidate are skipped rather than scored as 0.0 — an unlabelled
  query carries no information about a weighting, and counting it as a miss would let the
  metric be moved by label coverage instead of ranking quality.
  """
  @spec score([map()], labels(), keyword(), keyword()) :: %{
          ndcg: float(),
          mrr: float(),
          n: non_neg_integer()
        }
  def score(query_pools, labels, fusion_opts, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)

    scored =
      query_pools
      |> Enum.map(fn pool -> per_query(pool, labels, fusion_opts, k) end)
      |> Enum.reject(&is_nil/1)

    %{
      ndcg: RankingMetrics.mean(Enum.map(scored, & &1.ndcg)),
      mrr: RankingMetrics.mean(Enum.map(scored, & &1.mrr)),
      n: length(scored)
    }
  end

  @doc """
  Coordinate-ascent over per-arm weights, maximising mean nDCG@k.

  Returns the learned weights, the starting and final scores, and the number of rounds
  actually taken. `fusion_opts` supplies the mode: weights only bite under `:normalized`
  or `:hybrid`, so ascending with `fusion: :rrf` is a no-op by construction and reports a
  flat score rather than pretending to have learned something.
  """
  @spec ascend([map()], labels(), keyword()) :: map()
  def ascend(query_pools, labels, opts \\ []) do
    fusion_opts = Keyword.get(opts, :fusion_opts, fusion: :normalized, normalization: :min_max)
    grid = Keyword.get(opts, :grid, @default_grid)
    max_rounds = Keyword.get(opts, :max_rounds, @default_max_rounds)
    k = Keyword.get(opts, :k, @default_k)
    arms = Keyword.get_lazy(opts, :arms, fn -> arms_in(query_pools) end)

    baseline_weights = Map.new(arms, &{&1, 1.0})
    baseline = score(query_pools, labels, with_weights(fusion_opts, baseline_weights), k: k)

    {weights, best, rounds} =
      Enum.reduce_while(1..max_rounds//1, {baseline_weights, baseline.ndcg, 0}, fn round,
                                                                                   {weights, best,
                                                                                    _r} ->
        {next_weights, next_best} =
          Enum.reduce(arms, {weights, best}, fn arm, {acc_weights, acc_best} ->
            best_for_arm(query_pools, labels, fusion_opts, k, arm, grid, acc_weights, acc_best)
          end)

        if next_best > best do
          {:cont, {next_weights, next_best, round}}
        else
          {:halt, {weights, best, round - 1}}
        end
      end)

    %{
      weights: weights,
      baseline_ndcg: baseline.ndcg,
      learned_ndcg: best,
      delta: Float.round(best - baseline.ndcg, 12),
      rounds: rounds,
      arms: arms,
      n: baseline.n
    }
  end

  @doc "Fold learned weights into a fusion opts keyword list."
  @spec with_weights(keyword(), map()) :: keyword()
  def with_weights(fusion_opts, weights), do: Keyword.put(fusion_opts, :weights, weights)

  @doc "Arm names present anywhere in the pools, sorted for determinism."
  @spec arms_in([map()]) :: [String.t()]
  def arms_in(query_pools) do
    query_pools
    |> Enum.flat_map(fn pool ->
      pool
      |> get("candidates", [])
      |> Enum.flat_map(fn candidate ->
        candidate |> get("arm_ranks", %{}) |> Map.keys() |> Enum.map(&to_string/1)
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp best_for_arm(pools, labels, fusion_opts, k, arm, grid, weights, best) do
    Enum.reduce(grid, {weights, best}, fn value, {acc_weights, acc_best} ->
      trial = Map.put(acc_weights, arm, value)
      result = score(pools, labels, with_weights(fusion_opts, trial), k: k)

      # Strictly greater: ties keep the incumbent, which keeps ascent deterministic and
      # biased toward the simpler (earlier-visited) weighting.
      if result.ndcg > acc_best, do: {trial, result.ndcg}, else: {acc_weights, acc_best}
    end)
  end

  defp per_query(pool, labels, fusion_opts, k) do
    query_ref = get(pool, "query_ref", nil)

    relevance =
      pool
      |> get("candidates", [])
      |> Enum.reduce(%{}, fn candidate, acc ->
        ref = get(candidate, "memory_ref", nil)

        case Map.fetch(labels, {query_ref, ref}) do
          {:ok, grade} -> Map.put(acc, ref, grade)
          :error -> acc
        end
      end)

    if map_size(relevance) == 0 do
      nil
    else
      ranked = PoolFusion.rank(pool, fusion_opts)

      %{
        ndcg: RankingMetrics.ndcg_at_k(ranked, relevance, k),
        mrr: RankingMetrics.mrr(ranked, relevance)
      }
    end
  end

  defp get(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          ArgumentError -> default
        end
    end
  end

  defp get(_map, _key, default), do: default
end
