defmodule Foresight.Embedders.Bumblebee do
  @moduledoc false

  @behaviour Foresight.Embedder

  @default_dim 384

  @impl true
  def dimension(_opts), do: {:ok, @default_dim}

  @impl true
  def embed(text, opts) when is_binary(text) do
    serving_name =
      Keyword.get(opts, :serving, ml_serving_name())

    case apply(nx_serving_module(), :batched_run, [serving_name, text]) do
      %{embedding: embedding} -> {:ok, apply(nx_module(), :to_flat_list, [embedding])}
      [%{embedding: embedding}] -> {:ok, apply(nx_module(), :to_flat_list, [embedding])}
      other -> {:error, {:unexpected_embedding_response, other}}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  @impl true
  def embed_many(texts, opts) when is_list(texts) do
    serving_name =
      Keyword.get(opts, :serving, ml_serving_name())

    case apply(nx_serving_module(), :batched_run, [serving_name, texts]) do
      embeddings when is_list(embeddings) ->
        {:ok, Enum.map(embeddings, &normalize_embedding!/1)}

      other ->
        {:error, {:unexpected_embedding_batch_response, other}}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp normalize_embedding!(%{embedding: embedding}),
    do: apply(nx_module(), :to_flat_list, [embedding])

  defp normalize_embedding!([%{embedding: embedding}]),
    do: apply(nx_module(), :to_flat_list, [embedding])

  defp normalize_embedding!(other),
    do: raise("Unexpected embedding response: #{inspect(other)}")

  defp ml_serving_name do
    case Application.get_env(:foresight, :ml, []) do
      config when is_list(config) -> Keyword.get(config, :serving_name, Foresight.ML.Serving)
      config when is_map(config) -> Map.get(config, :serving_name, Foresight.ML.Serving)
      _other -> Foresight.ML.Serving
    end
  end

  defp nx_module, do: :"Elixir.Nx"
  defp nx_serving_module, do: :"Elixir.Nx.Serving"
end
