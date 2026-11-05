defmodule Foresight.Embedders.SentenceTransformers do
  @moduledoc false

  @behaviour Foresight.Embedder

  @impl true
  def dimension(opts) do
    worker(opts).dimension(worker_opts(opts))
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    worker(opts).embed(text, worker_opts(opts))
  end

  @impl true
  def embed_many(texts, opts) when is_list(texts) do
    worker(opts).embed_many(texts, worker_opts(opts))
  end

  defp worker(opts), do: Keyword.get(opts, :worker_module, Foresight.ML.PythonLocalWorker)

  defp worker_opts(opts) do
    Keyword.delete(opts, :worker_module)
  end
end
