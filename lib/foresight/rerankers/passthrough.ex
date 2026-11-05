defmodule Foresight.Rerankers.Passthrough do
  @moduledoc false

  @behaviour Foresight.Reranker

  @impl true
  def rerank(_query, candidates, _opts) do
    {:ok,
     candidates
     |> Enum.sort_by(fn candidate ->
       {-(candidate["rrf_score"] || candidate["score"] || 0.0), candidate["id"]}
     end)
     |> Enum.with_index(1)
     |> Enum.map(fn {candidate, rank} ->
       Map.put(candidate, "rerank_score", reseeded_rank_score(rank, length(candidates)))
     end)}
  end

  defp reseeded_rank_score(_rank, 0), do: 0.0
  defp reseeded_rank_score(_rank, 1), do: 1.0

  defp reseeded_rank_score(rank, total) do
    step = 0.9 / max(total - 1, 1)
    Float.round(1.0 - (rank - 1) * step, 6)
  end
end
