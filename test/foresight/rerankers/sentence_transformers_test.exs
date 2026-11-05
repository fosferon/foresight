defmodule Foresight.Rerankers.SentenceTransformersTest do
  use ExUnit.Case, async: true

  defmodule FakeWorker do
    def rerank(_query, _candidates, _opts), do: {:ok, [0.1, 0.9]}
  end

  test "scores and sorts candidates via the configured worker" do
    candidates = [
      %{"id" => "a", "content" => "first", "rrf_score" => 0.3},
      %{"id" => "b", "content" => "second", "rrf_score" => 0.1}
    ]

    assert {:ok, [%{"id" => "b"} = high, %{"id" => "a"} = low]} =
             Foresight.Rerankers.SentenceTransformers.rerank("query", candidates,
               worker_module: FakeWorker
             )

    assert high["raw_rerank_score"] == 0.9
    assert low["raw_rerank_score"] == 0.1
    assert high["rerank_score"] > low["rerank_score"]
    assert high["rerank_score"] < 1.0
    assert low["rerank_score"] > 0.0
  end

  test "short-circuits on empty candidates without calling the worker" do
    defmodule RaisingWorker do
      def rerank(_query, _candidates, _opts), do: raise("worker must not be called for []")
    end

    assert {:ok, []} =
             Foresight.Rerankers.SentenceTransformers.rerank("query", [],
               worker_module: RaisingWorker
             )
  end

  test "coerces a bare scalar score for a single candidate (no length/1 crash on recall)" do
    defmodule ScalarWorker do
      # A length-1 cross-encoder predict can squeeze to a bare float instead of a
      # one-element list — this used to raise "1st argument: not a list" in recall.
      def rerank(_query, _candidates, _opts), do: {:ok, 0.73}
    end

    assert {:ok, [%{"id" => "only"} = scored]} =
             Foresight.Rerankers.SentenceTransformers.rerank(
               "query",
               [%{"id" => "only", "content" => "sole candidate", "rrf_score" => 0.2}],
               worker_module: ScalarWorker
             )

    assert scored["raw_rerank_score"] == 0.73
    assert scored["rerank_score"] > 0.0 and scored["rerank_score"] < 1.0
  end

  test "fails closed when the worker returns a mismatched number of scores" do
    defmodule BadWorker do
      def rerank(_query, _candidates, _opts), do: {:ok, [0.4]}
    end

    assert {:error, message} =
             Foresight.Rerankers.SentenceTransformers.rerank(
               "query",
               [%{"id" => "a", "content" => "first"}, %{"id" => "b", "content" => "second"}],
               worker_module: BadWorker
             )

    assert message =~ "returned 1 scores for 2 candidates"
  end

  test "fails closed when the worker returns a non-numeric score" do
    defmodule NilScoreWorker do
      def rerank(_query, _candidates, _opts), do: {:ok, [nil, 0.2]}
    end

    assert {:error, message} =
             Foresight.Rerankers.SentenceTransformers.rerank(
               "query",
               [%{"id" => "a", "content" => "x"}, %{"id" => "b", "content" => "y"}],
               worker_module: NilScoreWorker
             )

    assert message =~ "non-numeric score"
  end
end
