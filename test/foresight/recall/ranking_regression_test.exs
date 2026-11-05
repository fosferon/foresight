defmodule Foresight.Recall.RankingRegressionTest do
  use ExUnit.Case, async: false

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
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    {:ok, ctx: %Foresight.Context{tenant_id: "default", mode: :mode_a, bank: "fosferon"}}
  end

  test "recall ranking stays deterministic against the fixed golden fixture", %{ctx: ctx} do
    fixture =
      Path.expand("../../../priv/foresight/fixtures/recall/golden_ranking.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, _} = Foresight.retain(ctx, %{"items" => fixture["items"]})

    payload = %{
      "query" => fixture["query"],
      "query_timestamp" => fixture["query_timestamp"]
    }

    assert {:ok, %{"results" => first_results}} = Foresight.recall(ctx, payload)
    assert {:ok, %{"results" => second_results}} = Foresight.recall(ctx, payload)

    first_order = Enum.map(first_results, & &1["text"])
    second_order = Enum.map(second_results, & &1["text"])

    assert first_order == fixture["expected_order"]
    assert second_order == fixture["expected_order"]
  end
end
