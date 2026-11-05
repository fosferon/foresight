defmodule Foresight.Embedders.SentenceTransformersTest do
  use ExUnit.Case, async: true

  defmodule FakeWorker do
    def dimension(opts), do: {:ok, Keyword.get(opts, :dimension, 384)}
    def embed(text, _opts), do: {:ok, [String.length(text) * 1.0, 2.0, 3.0]}
    def embed_many(texts, _opts), do: {:ok, Enum.map(texts, &[String.length(&1) * 1.0, 2.0, 3.0])}
  end

  test "delegates dimension lookup to the configured worker" do
    assert {:ok, 768} =
             Foresight.Embedders.SentenceTransformers.dimension(
               worker_module: FakeWorker,
               dimension: 768
             )
  end

  test "delegates embedding to the configured worker" do
    assert {:ok, [5.0, 2.0, 3.0]} =
             Foresight.Embedders.SentenceTransformers.embed("hello",
               worker_module: FakeWorker
             )
  end

  test "delegates batch embedding to the configured worker" do
    assert {:ok, [[5.0, 2.0, 3.0], [7.0, 2.0, 3.0]]} =
             Foresight.Embedders.SentenceTransformers.embed_many(["hello", "goodbye"],
               worker_module: FakeWorker
             )
  end
end
