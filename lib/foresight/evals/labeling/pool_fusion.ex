defmodule Foresight.Evals.Labeling.PoolFusion do
  @moduledoc """
  Re-rank a recorded candidate pool under a trial fusion configuration, offline.

  This is what makes the fusion tuner's coordinate ascent affordable: scoring a candidate weighting
  costs a pure re-fusion of an already-recorded pool instead of a live recall run over the
  corpus.

  It deliberately calls `Foresight.Recall.RRF.fuse/2` — the real fuser — rather than
  reimplementing the scoring. A reimplementation would be free to drift from production,
  and a tuner that optimises against a drifted model of the system produces weights that do
  not transfer. The only work here is reconstructing the `strategy_results` shape the fuser
  expects from what the pool recorded.

  RANK FIDELITY. `RRF.fuse/2` derives each arm's rank from list position via
  `Enum.with_index/2`, but a recorded pool is not dense: candidates are dropped when they
  lack a stable eval_id, and `per_query_cap` truncates. Handing it a compacted list would
  silently promote candidates — a candidate recorded at rank 9 would score as if it ranked
  4. So gaps are filled with placeholder entries that occupy the missing positions and are
  discarded from the result.
  """

  alias Foresight.Recall.RRF

  @placeholder_prefix "__pool_fusion_gap__"

  @doc """
  Rank one query pool's candidates under `fusion_opts`.

  Returns `memory_ref`s, most relevant first. `fusion_opts` is whatever
  `Foresight.Recall.FusionConfig.resolve/2` produces.
  """
  @spec rank(map(), keyword()) :: [String.t()]
  def rank(query_pool, fusion_opts \\ []) do
    query_pool
    |> strategy_results()
    |> RRF.fuse(fusion_opts)
    |> Enum.map(& &1["id"])
    |> Enum.reject(&placeholder?/1)
  end

  @doc """
  Rebuild the `arm => ranked items` map the live fuser consumes.

  Exposed so a test can assert the reconstruction itself, independently of ranking.
  """
  @spec strategy_results(map()) :: %{String.t() => [map()]}
  def strategy_results(query_pool) do
    candidates = fetch(query_pool, "candidates") || []

    candidates
    |> Enum.flat_map(fn candidate ->
      ref = fetch(candidate, "memory_ref")
      ranks = fetch(candidate, "arm_ranks") || %{}
      scores = fetch(candidate, "arm_scores") || %{}

      Enum.map(ranks, fn {arm, rank} ->
        {arm, rank, item(ref, arm, Map.get(scores, arm, Map.get(scores, to_string(arm), 0.0)))}
      end)
    end)
    |> Enum.group_by(fn {arm, _rank, _item} -> to_string(arm) end)
    |> Map.new(fn {arm, entries} -> {arm, dense_list(entries)} end)
  end

  # Places each item at its recorded rank, filling any gap with a placeholder so the
  # fuser's positional rank matches what recall actually produced.
  defp dense_list(entries) do
    by_rank = Map.new(entries, fn {_arm, rank, item} -> {rank, item} end)
    max_rank = by_rank |> Map.keys() |> Enum.max(fn -> 0 end)

    for rank <- 1..max_rank//1 do
      Map.get_lazy(by_rank, rank, fn -> placeholder(rank) end)
    end
  end

  defp item(ref, arm, score) do
    %{"id" => ref, "#{arm}_score" => score}
  end

  defp placeholder(rank) do
    %{"id" => "#{@placeholder_prefix}#{rank}"}
  end

  defp placeholder?(id) when is_binary(id), do: String.starts_with?(id, @placeholder_prefix)
  defp placeholder?(_id), do: false

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key), nil)
    end
  rescue
    ArgumentError -> nil
  end

  defp fetch(_map, _key), do: nil
end
