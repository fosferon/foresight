defmodule Foresight.Evals.HoldoutRecallEvalTest do
  @moduledoc """
  The honest held-out recall baseline.

  Runs the held-out garden corpus through the (decontaminated) recall pipeline and scores
  it with ID-based ranking metrics — nDCG@10, MRR, Recall@5 — that cannot be satisfied by
  emitting a corpus phrase. This exercises the same honest ranking algorithm as production
  (mirrored into FakeStorage), deterministically and without a database or ML runtime, so
  the number is reproducible and is the "first real measurement" after removing the gaming.

  The assertions are deliberately loose floors: this test exists to PRODUCE and guard a
  baseline, not to encode a target. Real semantic structure (graph,
  supersession) should raise the bar; the live Python-Hindsight comparator and the
  real-Ecto/ML lane are the next measurement steps.
  """
  use ExUnit.Case, async: false

  alias Foresight.Context
  alias Foresight.Evals.RankingMetrics, as: M
  alias Foresight.TestSupport.Evals.HoldoutCorpus

  @k 10
  @recall_k 5

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    start_supervised!(Foresight.TestSupport.FakeStorage)
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)
    Foresight.TestSupport.FakeStorage.reset!()
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.TestSupport.FakeStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: Foresight.TestSupport.FakeLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    on_exit(fn ->
      restore(:backend, original_backend)
      restore(:engine, original_engine)
    end)

    :ok
  end

  test "held-out recall baseline (nDCG@10 / MRR / Recall@5)" do
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "holdout-eval"}

    items =
      Enum.map(HoldoutCorpus.memories(), fn m ->
        Map.put(m, "metadata", %{"eval_id" => m["id"]})
      end)

    assert {:ok, _} = Foresight.retain(ctx, %{"items" => items})

    per_query =
      for q <- HoldoutCorpus.queries() do
        {:ok, %{"results" => results}} =
          Foresight.recall(ctx, %{"query" => q.query, "query_timestamp" => q.query_timestamp})

        ranked_ids =
          results
          |> Enum.map(fn r -> get_in(r, ["metadata", "eval_id"]) end)
          |> Enum.reject(&is_nil/1)

        %{
          id: q.id,
          class: q.class,
          ndcg: M.ndcg_at_k(ranked_ids, q.relevance, @k),
          mrr: M.mrr(ranked_ids, q.relevance),
          recall: M.recall_at_k(ranked_ids, q.relevance, @recall_k)
        }
      end

    ndcg = M.mean(Enum.map(per_query, & &1.ndcg))
    mrr = M.mean(Enum.map(per_query, & &1.mrr))
    recall = M.mean(Enum.map(per_query, & &1.recall))

    report(per_query, ndcg, mrr, recall)

    # Floors set just below the observed honest baseline (nDCG 0.971 / MRR 1.0 / Recall
    # 0.917) so a real ranking regression trips them, not merely a collapse to random.
    # NOTE: this is a fast, deterministic SMOKE TEST on a 10-memory corpus with a lexical
    # reranker — it is NOT the authoritative recall-quality measure. Real quality is the
    # LongMemEval harness on the Ecto + embedding-model lane (Foresight.Evals.Runner);
    # this only guards the decontaminated ranking plumbing against regression.
    assert recall >= 0.85, "mean Recall@#{@recall_k} regressed to #{recall} (baseline 0.917)"
    assert mrr >= 0.9, "mean MRR regressed to #{mrr} (baseline 1.0)"
    assert ndcg >= 0.9, "mean nDCG@#{@k} regressed to #{ndcg} (baseline 0.971)"
  end

  defp report(per_query, ndcg, mrr, recall) do
    IO.puts("\n=== Held-out recall baseline (honest, decontaminated ranking) ===")

    IO.puts(
      String.pad_trailing("query", 22) <>
        String.pad_trailing("class", 12) <>
        "nDCG@#{@k}   MRR    Recall@#{@recall_k}"
    )

    for r <- per_query do
      IO.puts(
        String.pad_trailing(r.id, 22) <>
          String.pad_trailing(r.class, 12) <>
          "#{fmt(r.ndcg)}   #{fmt(r.mrr)}   #{fmt(r.recall)}"
      )
    end

    IO.puts(
      String.pad_trailing("MEAN", 34) <>
        "#{fmt(ndcg)}   #{fmt(mrr)}   #{fmt(recall)}\n"
    )
  end

  defp fmt(v), do: :erlang.float_to_binary(v * 1.0, decimals: 3)

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
