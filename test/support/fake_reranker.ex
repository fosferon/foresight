defmodule Foresight.TestSupport.FakeReranker do
  @moduledoc false

  @behaviour Foresight.Reranker

  @impl true
  def rerank(query, candidates, _opts) do
    {:ok,
     candidates
     |> Enum.map(fn candidate ->
       Map.put(candidate, "rerank_score", fake_rerank_score(query, candidate))
     end)
     |> Enum.sort_by(fn candidate ->
       {-(candidate["rerank_score"] || 0.0), -(candidate["rrf_score"] || 0.0), candidate["id"]}
     end)}
  end

  defp fake_rerank_score(query, candidate) do
    haystack = "#{candidate["content"]} #{candidate["context"]}" |> String.downcase()

    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(&1 in ["what", "did", "say", "about", "the", "a", "an", "of", "to", "in"]))
    |> Enum.uniq()
    |> then(fn tokens ->
      lexical =
        case tokens do
          [] -> 0.0
          _ -> Enum.count(tokens, &String.contains?(haystack, &1)) / length(tokens)
        end

      lexical + (candidate["rrf_score"] || 0.0)
    end)
    |> Float.round(6)
  end
end
