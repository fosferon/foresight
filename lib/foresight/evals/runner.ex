defmodule Foresight.Evals.Runner do
  @moduledoc """
  Dataset-agnostic eval runner. Given normalised `Dataset.Instance`s and a `recall_fun`, it
  scores each query with the gaming-resistant ranking metrics and aggregates overall and per
  `question_type`.

  `recall_fun` is injected so the same orchestration runs against the real
  Ecto+pgvector+embedder pipeline (the honest measurement) or a deterministic stub (to unit
  test the aggregation without a database). It receives a `Dataset.Instance` and returns the
  recall response's `results` list (ranked, each result echoing `metadata["eval_id"]`).
  """

  alias Foresight.Evals.Dataset
  alias Foresight.Evals.RankingMetrics, as: M

  @default_k 10
  @default_recall_k 5

  @type recall_fun :: (Dataset.t() -> [map()])

  @doc """
  Run the harness. Options: `:k` (nDCG/precision depth, default 10), `:recall_k` (default
  5). Returns `%{overall: metrics, by_type: %{type => metrics}, per_query: [...]}` where
  `metrics` is `%{n, ndcg, mrr, recall}`.
  """
  @spec run([Dataset.t()], recall_fun(), keyword()) :: map()
  def run(instances, recall_fun, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)
    recall_k = Keyword.get(opts, :recall_k, @default_recall_k)

    per_query =
      Enum.map(instances, fn inst ->
        ranked = inst |> recall_fun.() |> Dataset.ranked_eval_ids()

        %{
          id: inst.id,
          type: inst.question_type,
          ndcg: M.ndcg_at_k(ranked, inst.relevance, k),
          mrr: M.mrr(ranked, inst.relevance),
          recall: M.recall_at_k(ranked, inst.relevance, recall_k)
        }
      end)

    %{
      overall: aggregate(per_query),
      by_type:
        per_query |> Enum.group_by(& &1.type) |> Map.new(fn {t, rows} -> {t, aggregate(rows)} end),
      per_query: per_query
    }
  end

  @doc "Aggregate a list of per-query metric rows into means."
  @spec aggregate([map()]) :: map()
  def aggregate(rows) do
    %{
      n: length(rows),
      ndcg: M.mean(Enum.map(rows, & &1.ndcg)),
      mrr: M.mean(Enum.map(rows, & &1.mrr)),
      recall: M.mean(Enum.map(rows, & &1.recall))
    }
  end

  @doc "Render a report table (overall + per question_type) as a string."
  @spec format_report(map(), keyword()) :: String.t()
  def format_report(%{overall: overall, by_type: by_type}, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)
    recall_k = Keyword.get(opts, :recall_k, @default_recall_k)
    header = ["question_type", "n", "nDCG@#{k}", "MRR", "Recall@#{recall_k}"]

    rows =
      by_type
      |> Enum.sort_by(fn {t, _} -> t end)
      |> Enum.map(fn {t, m} -> [t, m.n, m.ndcg, m.mrr, m.recall] end)

    ([header] ++
       Enum.map(rows, &fmt_row/1) ++
       [fmt_row(["OVERALL", overall.n, overall.ndcg, overall.mrr, overall.recall])])
    |> Enum.map_join("\n", fn cols ->
      cols
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.pad_trailing(&1, 26))
      |> Enum.join()
    end)
  end

  defp fmt_row([label, n | metrics]) do
    [label, n | Enum.map(metrics, &num/1)]
  end

  defp num(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 3)
  defp num(v), do: to_string(v)
end
