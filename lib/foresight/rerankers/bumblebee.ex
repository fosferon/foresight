defmodule Foresight.Rerankers.Bumblebee do
  @moduledoc false

  @behaviour Foresight.Reranker

  @impl true
  def rerank(query, candidates, opts) when is_binary(query) and is_list(candidates) do
    serving_name = Keyword.get(opts, :reranker_serving_name, ml_config(:reranker_serving_name))

    # Score the date/context-aware passage, not bare content, matching
    # Hindsight's cross-encoder input.
    pairs = Enum.map(candidates, &{query, Foresight.Rerankers.Passage.build(&1)})

    scores =
      case apply(nx_serving_module(), :batched_run, [serving_name, pairs]) do
        outputs when is_list(outputs) ->
          Enum.map(outputs, &extract_score/1)

        output ->
          [extract_score(output)]
      end

    reranked =
      candidates
      |> Enum.zip(scores)
      |> Enum.map(fn {candidate, score} ->
        raw_score = Float.round(score, 6)

        candidate
        |> Map.put("raw_rerank_score", raw_score)
        |> Map.put("rerank_score", normalize_rerank_score(score))
      end)
      |> Enum.sort_by(fn candidate ->
        {-(candidate["rerank_score"] || 0.0), -(candidate["rrf_score"] || 0.0), candidate["id"]}
      end)

    {:ok, reranked}
  rescue
    error in UndefinedFunctionError ->
      {:error, error}
  end

  defp extract_score(%{score: score}) when is_number(score), do: score
  defp extract_score(%{"score" => score}) when is_number(score), do: score
  defp extract_score(score) when is_number(score), do: score
  defp extract_score(_other), do: 0.0

  defp normalize_rerank_score(score) when is_number(score) do
    Float.round(1.0 / (1.0 + :math.exp(-score)), 6)
  end

  defp ml_config(key) do
    case Application.get_env(:foresight, :ml, []) do
      config when is_list(config) -> Keyword.get(config, key, Foresight.ML.RerankerServing)
      config when is_map(config) -> Map.get(config, key, Foresight.ML.RerankerServing)
      _other -> Foresight.ML.RerankerServing
    end
  end

  defp nx_serving_module, do: :"Elixir.Nx.Serving"
end
