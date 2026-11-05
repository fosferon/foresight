defmodule Foresight.Rerankers.SentenceTransformers do
  @moduledoc false

  @behaviour Foresight.Reranker

  @impl true
  def rerank(_query, [] = _candidates, _opts), do: {:ok, []}

  def rerank(query, candidates, opts) when is_binary(query) and is_list(candidates) do
    # The worker reranks each candidate's "content"; swap in the date/context-aware
    # passage for scoring, then zip the scores back onto the ORIGINAL
    # candidates so their real content is preserved downstream.
    passage_candidates =
      Enum.map(candidates, &Map.put(&1, "content", Foresight.Rerankers.Passage.build(&1)))

    case worker(opts).rerank(query, passage_candidates, worker_opts(opts)) do
      {:ok, raw_scores} ->
        # A single-candidate rerank can come back as a bare scalar score (the
        # cross-encoder squeezes a length-1 result), so coerce to a list before
        # the count check — otherwise length/1 raises "not a list" on recall.
        scores = List.wrap(raw_scores)

        with :ok <- ensure_score_count(scores, candidates) do
          reranked =
            candidates
            |> Enum.zip(scores)
            |> Enum.map(fn {candidate, score} ->
              raw_score = Float.round(score * 1.0, 6)

              candidate
              |> Map.put("raw_rerank_score", raw_score)
              |> Map.put("rerank_score", normalize_rerank_score(score))
            end)
            |> Enum.sort_by(fn candidate ->
              {-(candidate["rerank_score"] || 0.0), -(candidate["rrf_score"] || 0.0),
               candidate["id"]}
            end)

          {:ok, reranked}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_score_count(scores, candidates)
       when is_list(scores) and length(scores) == length(candidates) do
    # The worker refuses to emit NaN/inf and erlport cannot encode them, but a
    # malformed score must still fail closed here rather than rank the candidates
    # by garbage.
    if Enum.all?(scores, &is_number/1) do
      :ok
    else
      {:error, "SentenceTransformers reranker returned a non-numeric score"}
    end
  end

  defp ensure_score_count(scores, candidates) do
    {:error,
     "SentenceTransformers reranker returned #{length(List.wrap(scores))} scores " <>
       "for #{length(candidates)} candidates"}
  end

  defp worker(opts), do: Keyword.get(opts, :worker_module, Foresight.ML.PythonLocalWorker)

  # The worker returns raw cross-encoder logits (priv/python/sentence_transformers_worker.py
  # pins the model's activation to Identity, since some models default to Sigmoid);
  # this is the ONE sigmoid that turns a logit into rerank_score. Do not add another
  # on either side.
  defp normalize_rerank_score(score) when is_number(score) do
    Float.round(1.0 / (1.0 + :math.exp(-score)), 6)
  end

  defp worker_opts(opts) do
    Keyword.delete(opts, :worker_module)
  end
end
