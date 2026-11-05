defmodule Foresight.Evals.RunnerTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.Dataset
  alias Foresight.Evals.Runner

  defp inst(id, type, memory_ids, relevance) do
    %Dataset{
      id: id,
      query: "q",
      question_type: type,
      memories: Enum.map(memory_ids, &%{"id" => &1}),
      relevance: relevance
    }
  end

  # A recall stub: returns results in a fixed, prescribed order per instance id, shaped like
  # real recall results (metadata.eval_id). Lets us prove the runner's scoring/aggregation
  # deterministically, with no database.
  defp stub(order_by_id) do
    fn %Dataset{id: id} ->
      Enum.map(Map.fetch!(order_by_id, id), fn eid -> %{"metadata" => %{"eval_id" => eid}} end)
    end
  end

  test "scores each query and aggregates overall + per type" do
    instances = [
      inst("a", "temporal", ["m1", "m2"], %{"m1" => 1, "m2" => 0}),
      inst("b", "temporal", ["m3", "m4"], %{"m3" => 1}),
      inst("c", "multi", ["m5", "m6"], %{"m6" => 1})
    ]

    # a: perfect (relevant first). b: perfect. c: relevant is SECOND (mrr 0.5).
    recall =
      stub(%{
        "a" => ["m1", "m2"],
        "b" => ["m3", "m4"],
        "c" => ["m5", "m6"]
      })

    result = Runner.run(instances, recall, k: 10, recall_k: 5)

    assert result.overall.n == 3
    # MRR: a=1.0, b=1.0, c=0.5 → mean 0.8333
    assert_in_delta result.overall.mrr, (1.0 + 1.0 + 0.5) / 3, 1.0e-9
    # Recall@5: all relevant items appear → 1.0 each
    assert result.overall.recall == 1.0

    assert result.by_type["temporal"].n == 2
    assert result.by_type["temporal"].mrr == 1.0
    assert result.by_type["multi"].n == 1
    assert result.by_type["multi"].mrr == 0.5
  end

  test "a broken retriever (relevant items never surfaced) scores near zero" do
    instances = [inst("a", "t", ["m1", "m2"], %{"m1" => 1})]
    # recall returns only the irrelevant memory
    recall = stub(%{"a" => ["m2"]})

    result = Runner.run(instances, recall)

    assert result.overall.mrr == 0.0
    assert result.overall.ndcg == 0.0
    assert result.overall.recall == 0.0
  end

  test "format_report renders overall and per-type rows" do
    instances = [inst("a", "temporal", ["m1"], %{"m1" => 1})]
    report = instances |> Runner.run(stub(%{"a" => ["m1"]})) |> Runner.format_report()

    assert report =~ "question_type"
    assert report =~ "temporal"
    assert report =~ "OVERALL"
  end
end
