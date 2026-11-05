defmodule Foresight.ML.RerankerServingTest do
  use ExUnit.Case, async: false

  @moduletag :ml
  @moduletag timeout: 300_000

  test "loads the default cross-encoder reranker and prefers the more relevant candidate" do
    serving_name = Module.concat(__MODULE__, Serving)

    start_supervised!(
      {Foresight.ML.RerankerServing,
       name: serving_name, model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2"}
    )

    candidates = [
      %{"id" => "irrelevant", "content" => "A recipe for roasting potatoes.", "rrf_score" => 0.4},
      %{
        "id" => "relevant",
        "content" => "Foresight is an Elixir memory system with retrieval and reflection.",
        "rrf_score" => 0.3
      }
    ]

    assert {:ok, reranked} =
             Foresight.Rerankers.Bumblebee.rerank("What is Foresight?", candidates,
               reranker_serving_name: serving_name
             )

    assert Enum.map(reranked, & &1["id"]) == ["relevant", "irrelevant"]

    assert Enum.all?(reranked, fn candidate ->
             is_float(candidate["rerank_score"])
           end)

    assert hd(reranked)["rerank_score"] > List.last(reranked)["rerank_score"]
  end

  test "accepts map-backed :foresight, :ml config like FullMLAuthority" do
    previous_ml = Application.get_env(:foresight, :ml)
    serving_name = Module.concat(__MODULE__, MapConfigServing)

    Application.put_env(:foresight, :ml, %{
      enabled: true,
      reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
      reranker_serving_name: serving_name
    })

    on_exit(fn ->
      if is_nil(previous_ml) do
        Application.delete_env(:foresight, :ml)
      else
        Application.put_env(:foresight, :ml, previous_ml)
      end
    end)

    start_supervised!({Foresight.ML.RerankerServing, name: serving_name})

    candidates = [
      %{"id" => "irrelevant", "content" => "A recipe for roasting potatoes.", "rrf_score" => 0.4},
      %{
        "id" => "relevant",
        "content" => "Foresight is an Elixir memory system with retrieval and reflection.",
        "rrf_score" => 0.3
      }
    ]

    assert {:ok, reranked} =
             Foresight.Rerankers.Bumblebee.rerank("What is Foresight?", candidates, [])

    assert Enum.map(reranked, & &1["id"]) == ["relevant", "irrelevant"]
  end
end
