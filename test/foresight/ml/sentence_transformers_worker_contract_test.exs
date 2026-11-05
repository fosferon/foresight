defmodule Foresight.ML.SentenceTransformersWorkerContractTest do
  @moduledoc """
  Guards the logit contract between `priv/python/sentence_transformers_worker.py`
  and `Foresight.Rerankers.SentenceTransformers`: the worker hands back raw
  cross-encoder logits and the Elixir seam applies the single sigmoid.

  Two layers:

    * the always-on test proves the Elixir side applies exactly one sigmoid;
    * the `:ml` test runs the real Python worker against a model whose own default
      activation is `Sigmoid` (`BAAI/bge-reranker-v2-m3`) and asserts the worker
      reports an `Identity` activation and returns a negative raw score for an
      unrelated pair — which is impossible if a sigmoid ran on the Python side.
      Excluded from the default suite; needs `FORESIGHT_ML_PYTHON` pointing at an
      interpreter with torch + sentence-transformers and the model in the HF cache
      (`FORESIGHT_TEST_INCLUDE_TAGS=ml`).
  """
  use ExUnit.Case, async: false

  alias Foresight.ML.PythonLocalWorker

  test "the Elixir seam is the single sigmoid: a 0 logit maps to 0.5, a large one near 1" do
    defmodule LogitWorker do
      def rerank(_query, _candidates, _opts), do: {:ok, [0.0, 11.0, -11.0]}
    end

    candidates = for id <- ~w(zero high low), do: %{"id" => id, "content" => id}

    assert {:ok, ranked} =
             Foresight.Rerankers.SentenceTransformers.rerank("q", candidates,
               worker_module: LogitWorker
             )

    scores = Map.new(ranked, &{&1["id"], &1["rerank_score"]})
    assert_in_delta scores["zero"], 0.5, 1.0e-6
    assert scores["high"] > 0.9999
    assert scores["low"] < 0.0001
    assert Enum.map(ranked, & &1["id"]) == ~w(high zero low)
  end

  @tag :ml
  @tag timeout: 600_000
  test "the real worker scores a sigmoid-default model with an Identity activation (raw logits)" do
    python = System.get_env("FORESIGHT_ML_PYTHON")

    assert is_binary(python) and File.exists?(python),
           "FORESIGHT_ML_PYTHON must point at a venv python"

    name = :"st_worker_contract_#{System.unique_integer([:positive])}"

    start_supervised!(
      {PythonLocalWorker,
       name: name,
       python_executable: python,
       reranker_model_id: "BAAI/bge-reranker-v2-m3",
       preload_models: false}
    )

    assert {:ok, info} = PythonLocalWorker.device_info(name: name)
    assert info["reranker_activation"] == "Identity"

    unrelated = [%{"content" => "Only you can change your beliefs | Involving: you"}]
    related = [%{"content" => "Only you can change your beliefs | Involving: you"}]

    assert {:ok, [off_topic]} =
             PythonLocalWorker.rerank("What is a good recipe for lasagna?", unrelated, name: name)

    assert {:ok, [match]} =
             PythonLocalWorker.rerank(
               "Who is the only one who can change what I believe?",
               related,
               name: name
             )

    # A sigmoid on the Python side would bound both into (0, 1); raw logits do not.
    assert off_topic < 0.0
    assert match > off_topic
  end

  @tag :ml
  @tag timeout: 600_000
  test "the real worker honours a per-call embedder model (bank-level embed_model)" do
    python = System.get_env("FORESIGHT_ML_PYTHON")

    assert is_binary(python) and File.exists?(python),
           "FORESIGHT_ML_PYTHON must point at a venv python"

    name = :"st_worker_models_#{System.unique_integer([:positive])}"

    start_supervised!(
      {PythonLocalWorker,
       name: name,
       python_executable: python,
       model_id: "BAAI/bge-small-en-v1.5",
       preload_models: false}
    )

    # Engine default (worker state) and a bank pinned to a different model, both
    # through the embedder the engine configures, i.e. the path a bank config PATCH
    # to embed_model/embedding_dim resolves through.
    assert {:ok, 384} = Foresight.Embedders.SentenceTransformers.dimension(name: name)

    assert {:ok, 1024} =
             Foresight.Embedders.SentenceTransformers.dimension(
               name: name,
               model_id: "BAAI/bge-m3"
             )

    assert {:ok, small} = Foresight.Embedders.SentenceTransformers.embed("hello", name: name)
    assert length(small) == 384

    assert {:ok, large} =
             Foresight.Embedders.SentenceTransformers.embed("hello",
               name: name,
               model_id: "BAAI/bge-m3"
             )

    assert length(large) == 1024

    # The default is untouched by the per-call override: the worker caches both.
    assert {:ok, 384} = Foresight.Embedders.SentenceTransformers.dimension(name: name)
  end
end
