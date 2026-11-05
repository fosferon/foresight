defmodule Foresight.Evals.Labeling.CandidatePool do
  @moduledoc """
  Relevance-labeling pipeline, candidate-pool step: pool the pre-fusion recall arms into the deduped candidate set
  to be labeled for a query.

  Input is the `strategy_items` map that escapes `ranked_recall_items/6` — `arm_name =>
  ranked item list`, each item shaped by `memory_unit_to_recall_response/2` (string `"id"`,
  `"content"`, `"context"`, and `metadata["eval_id"]` as the stable label key). We keep the
  top-K per arm, union across arms, dedup on the stable `memory_ref` (eval_id), and record
  EVERY arm's rank for each candidate (`arm_ranks`), plus the best rank and arm-name list.

  `arm_ranks` is what makes the pool re-fusable offline: RRF scores a candidate from each
  arm's rank, so the fusion tuner's coordinate ascent can rescore a whole pool under a trial weighting
  without re-running recall. Pools recorded before this existed carry only `best_rank` and
  must be regenerated before they can be ascended against.

  Candidates lacking a stable eval_id cannot be mapped to a reusable label, so they are
  dropped from the pool and returned under `:dropped` — the caller logs that as coverage
  loss rather than silently labeling against ephemeral ids. Pure: no DB, no recall call.
  """

  @default_top_k 20

  @type candidate :: %{
          memory_ref: String.t(),
          memory_id: String.t(),
          content: String.t() | nil,
          context: String.t() | nil,
          arms: [String.t()],
          arm_ranks: %{String.t() => pos_integer()},
          arm_scores: %{String.t() => float()},
          best_rank: pos_integer()
        }

  @doc """
  Pool `strategy_items` into `%{candidates: [candidate], dropped: [raw_item]}`.

  Options: `:top_k` (per-arm cap, default #{@default_top_k}).
  """
  @spec pool(%{optional(String.t()) => [map()]}, keyword()) :: %{
          candidates: [candidate()],
          dropped: [map()]
        }
  def pool(strategy_items, opts \\ []) when is_map(strategy_items) do
    top_k = Keyword.get(opts, :top_k, @default_top_k)

    tagged =
      Enum.flat_map(strategy_items, fn {arm, items} ->
        items
        |> Enum.take(top_k)
        |> Enum.with_index(1)
        |> Enum.map(fn {item, rank} -> {arm, rank, item} end)
      end)

    {labelable, dropped} =
      Enum.split_with(tagged, fn {_arm, _rank, item} -> stable_ref(item) != nil end)

    candidates =
      labelable
      |> Enum.group_by(fn {_arm, _rank, item} -> stable_ref(item) end)
      |> Enum.map(&merge_group/1)
      |> Enum.sort_by(&{&1.best_rank, &1.memory_ref})

    %{candidates: candidates, dropped: Enum.map(dropped, fn {_arm, _rank, item} -> item end)}
  end

  defp merge_group({memory_ref, entries}) do
    {_arm, _rank, exemplar} = Enum.min_by(entries, fn {_arm, rank, _item} -> rank end)

    arm_ranks =
      Enum.reduce(entries, %{}, fn {arm, rank, _item}, acc ->
        Map.update(acc, arm, rank, &min(&1, rank))
      end)

    arm_scores =
      Enum.reduce(entries, %{}, fn {arm, _rank, item}, acc ->
        Map.update(acc, arm, native_score(item, arm), &max(&1, native_score(item, arm)))
      end)

    %{
      memory_ref: memory_ref,
      memory_id: exemplar["id"],
      content: exemplar["content"],
      context: exemplar["context"],
      arms: arm_ranks |> Map.keys() |> Enum.sort(),
      # Native per-arm scores, mirroring RRF's own native_score/2 including its 0.0
      # default. Ranks alone are not enough: per-arm WEIGHTS only take effect under the
      # :normalized and :hybrid modes, and those normalize native scores, not ranks. A
      # pool without these cannot be re-fused under a trial weighting.
      arm_scores: arm_scores,
      # Per-arm ranks, not just the minimum: RRF scores a candidate from EVERY arm's rank,
      # so an offline re-fusion under different arm weights (the fusion tuner's coordinate ascent) is
      # impossible from best_rank alone. Kept alongside the original fields so existing
      # artifacts and consumers are unaffected.
      arm_ranks: arm_ranks,
      best_rank: arm_ranks |> Map.values() |> Enum.min()
    }
  end

  # Mirrors Foresight.Recall.RRF.native_score/2 exactly, including the 0.0 fallback, so a
  # re-fused pool scores identically to the live fuser.
  defp native_score(item, "semantic"), do: Map.get(item, "semantic_score", 0.0)
  defp native_score(item, "keyword"), do: Map.get(item, "keyword_score", 0.0)
  defp native_score(item, "graph"), do: Map.get(item, "graph_score", 0.0)
  defp native_score(item, "source_expansion"), do: Map.get(item, "source_expansion_score", 0.0)
  defp native_score(item, "temporal"), do: Map.get(item, "temporal_score", 0.0)
  defp native_score(_item, _strategy), do: 0.0

  defp stable_ref(item) do
    case get_in(item, ["metadata", "eval_id"]) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end
end
