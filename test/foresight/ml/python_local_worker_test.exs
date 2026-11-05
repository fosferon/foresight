defmodule Foresight.ML.PythonLocalWorkerTest do
  use ExUnit.Case, async: true

  alias Foresight.ML.PythonLocalWorker

  describe "model_overrides/1" do
    test "forwards a per-call embedder model so a bank pinned to another model reaches the worker" do
      assert PythonLocalWorker.model_overrides(model_id: "BAAI/bge-m3") ==
               %{embedder_model_id: "BAAI/bge-m3"}
    end

    test "forwards a per-call reranker model" do
      assert PythonLocalWorker.model_overrides(reranker_model_id: "BAAI/bge-reranker-v2-m3") ==
               %{reranker_model_id: "BAAI/bge-reranker-v2-m3"}
    end

    test "leaves the worker defaults in force when no model is named" do
      assert PythonLocalWorker.model_overrides([]) == %{}
      assert PythonLocalWorker.model_overrides(model_id: nil, embedding_dim: 1024) == %{}
      assert PythonLocalWorker.model_overrides(model_id: "") == %{}
      assert PythonLocalWorker.model_overrides(name: :some_worker, timeout: 5_000) == %{}
    end
  end
end
