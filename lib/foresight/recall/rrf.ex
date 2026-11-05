defmodule Foresight.Recall.RRF do
  @moduledoc """
  Rank/score fusion across recall arms. Three modes, selected by
  `:fusion`:

    * `:rrf` (DEFAULT) — classic reciprocal-rank fusion: score = Σ 1/(k+rank). Uses
      rank only, so it is robust but blind to the *gap* between rank 1 and rank 2 and
      to each arm's score magnitude.
    * `:normalized` — per-arm normalized native scores (min-max or z-score), summed with
      optional per-arm `:weights`, times an explicit multi-arm convergence bonus. Captures
      within-arm magnitude and makes arms comparable — beating RRF's rank-only view.
    * `:hybrid` — `rrf_score + :hybrid_alpha * normalized_score`, times the convergence
      bonus. Keeps RRF's robustness and adds calibrated magnitude.

  The convergence bonus (`:convergence_bonus` β, default 0.1) makes multi-arm agreement an
  explicit score term (`1 + β·(arms-1)`), not just a tiebreak. Per-arm `:weights` (default
  1.0 each) are the surface a learned per-bank tuner (`Foresight.Evals.Labeling.FusionTuner`) optimizes. `:rrf` output is
  byte-for-byte the behaviour from before calibrated fusion: no extra fields, same ordering.
  """

  @default_k 60
  @default_convergence_bonus 0.1
  @default_hybrid_alpha 1.0

  @spec fuse(map(), keyword()) :: [map()]
  def fuse(strategy_results, opts \\ []) when is_map(strategy_results) do
    k = Keyword.get(opts, :k, @default_k)

    strategy_results
    |> accumulate(k)
    |> finalize(Keyword.get(opts, :fusion, :rrf), opts)
  end

  # Reciprocal-rank accumulation (unchanged): merge each arm's items, summing 1/(k+rank)
  # into rrf_score and recording per-strategy contributions + native scores. Returned
  # unsorted; `finalize/3` orders per the fusion mode.
  defp accumulate(strategy_results, k) do
    strategy_results
    |> Enum.reduce(%{}, fn {strategy, items}, acc ->
      Enum.with_index(items, 1)
      |> Enum.reduce(acc, fn {item, rank}, item_acc ->
        contribution = 1.0 / (k + rank)
        detail = contribution_detail(item, strategy, contribution, rank)

        Map.update(
          item_acc,
          # Key on the memory id. Fall back to a content hash if an item lacks an id
          # so distinct id-less items do not all collapse onto the nil key (which
          # would silently drop results).
          item["id"] || {:no_id, :erlang.phash2(item)},
          seed_fused_item(item, strategy, contribution, detail),
          fn existing ->
            # Merge this strategy's item into the accumulator so strategy-specific
            # fields (keyword_score, graph_source_expansion, …) all survive fusion.
            # `Map.merge(item, existing)` lets the accumulator win on shared keys, so
            # the result is independent of strategy arrival order (strategies run
            # under Task.async_stream(ordered: false) — first-seen-wins would make
            # boosts, and therefore rankings, nondeterministic across runs).
            item
            |> Map.merge(existing)
            |> Map.put("rrf_score", Float.round(existing["rrf_score"] + contribution, 12))
            |> Map.put(
              "strategy_contributions",
              Map.put(existing["strategy_contributions"], strategy, contribution)
            )
            |> Map.put(
              "strategy_contribution_details",
              Map.put(existing["strategy_contribution_details"], strategy, detail)
            )
          end
        )
      end)
    end)
    |> Map.values()
  end

  # :rrf — sort by reciprocal-rank score exactly as before; add NO fields so the output is
  # identical to the original RRF-only fuser.
  defp finalize(items, :rrf, _opts) do
    Enum.sort_by(items, fn item ->
      {-item["rrf_score"], -map_size(item["strategy_contributions"]), item["id"]}
    end)
  end

  defp finalize(items, mode, opts) when mode in [:normalized, :hybrid] do
    normalization = Keyword.get(opts, :normalization, :min_max)
    weights = Keyword.get(opts, :weights, %{})
    beta = Keyword.get(opts, :convergence_bonus, @default_convergence_bonus)
    alpha = Keyword.get(opts, :hybrid_alpha, @default_hybrid_alpha)
    stats = arm_stats(items, normalization)

    items
    |> Enum.map(fn item ->
      normalized = normalized_score(item, stats, weights, normalization)
      convergence = map_size(item["strategy_contributions"])
      bonus = 1.0 + beta * (convergence - 1)

      base =
        case mode do
          :normalized -> normalized
          :hybrid -> item["rrf_score"] + alpha * normalized
        end

      item
      |> Map.put("normalized_score", Float.round(normalized, 12))
      |> Map.put("convergence", convergence)
      |> Map.put("fused_score", Float.round(base * bonus, 12))
    end)
    |> Enum.sort_by(fn item -> {-item["fused_score"], -item["convergence"], item["id"]} end)
  end

  # Per-strategy normalization parameters, computed over the native scores each arm
  # actually surfaced (an item absent from an arm contributes nothing to that arm's stats).
  defp arm_stats(items, normalization) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      Enum.reduce(item["strategy_contribution_details"], acc, fn {strategy, detail}, acc2 ->
        Map.update(acc2, strategy, [detail["native_score"]], &[detail["native_score"] | &1])
      end)
    end)
    |> Map.new(fn {strategy, scores} -> {strategy, stat(scores, normalization)} end)
  end

  defp stat(scores, :zscore) do
    n = length(scores)
    mean = Enum.sum(scores) / n
    variance = Enum.reduce(scores, 0.0, fn s, acc -> acc + (s - mean) * (s - mean) end) / n
    {:zscore, mean, :math.sqrt(variance)}
  end

  defp stat(scores, _min_max) do
    {:min_max, Enum.min(scores), Enum.max(scores)}
  end

  defp normalized_score(item, stats, weights, _normalization) do
    Enum.reduce(item["strategy_contribution_details"], 0.0, fn {strategy, detail}, acc ->
      weight = Map.get(weights, strategy, 1.0)
      acc + weight * normalize(detail["native_score"], Map.get(stats, strategy))
    end)
  end

  # An arm whose scores are all equal (or a single item) yields full presence credit
  # (1.0 for min-max, 0.0 for z-score) — never a divide-by-zero.
  defp normalize(_value, nil), do: 0.0

  defp normalize(value, {:min_max, min, max}) do
    if max == min, do: 1.0, else: (value - min) / (max - min)
  end

  defp normalize(value, {:zscore, mean, std}) do
    if std == 0.0, do: 0.0, else: (value - mean) / std
  end

  defp seed_fused_item(item, strategy, contribution, detail) do
    item
    |> Map.put("rrf_score", Float.round(contribution, 12))
    |> Map.put("strategy_contributions", %{strategy => contribution})
    |> Map.put("strategy_contribution_details", %{strategy => detail})
  end

  defp contribution_detail(item, strategy, contribution, rank) do
    %{
      "rrf_contribution" => Float.round(contribution, 12),
      "source_rank" => rank,
      "native_score" => native_score(item, strategy)
    }
  end

  defp native_score(item, "semantic"), do: Map.get(item, "semantic_score", 0.0)
  defp native_score(item, "keyword"), do: Map.get(item, "keyword_score", 0.0)
  defp native_score(item, "graph"), do: Map.get(item, "graph_score", 0.0)
  defp native_score(item, "source_expansion"), do: Map.get(item, "source_expansion_score", 0.0)
  defp native_score(item, "temporal"), do: Map.get(item, "temporal_score", 0.0)
  defp native_score(_item, _strategy), do: 0.0
end
