defmodule Foresight.ML.RerankerServing do
  @moduledoc false

  @default_model_id "cross-encoder/ms-marco-MiniLM-L-6-v2"

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [Keyword.put(opts, :name, name)]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    serving = build_cross_encoding_serving(opts)
    Nx.Serving.start_link(name: name, serving: serving)
  end

  def build_cross_encoding_serving(opts \\ []) do
    model_id = Keyword.get(opts, :model_id, ml_config(:reranker_model_id) || @default_model_id)

    {:ok, model_info} = Bumblebee.load_model({:hf, model_id})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})

    serving_opts =
      []
      |> maybe_put_compile_opts(
        Keyword.get(opts, :batch_size, ml_config(:reranker_batch_size)),
        Keyword.get(opts, :sequence_length, ml_config(:reranker_sequence_length))
      )

    Bumblebee.Text.cross_encoding(model_info, tokenizer, serving_opts)
  end

  defp maybe_put_compile_opts(opts, nil, _sequence_length), do: opts
  defp maybe_put_compile_opts(opts, _batch_size, nil), do: opts

  defp maybe_put_compile_opts(opts, batch_size, sequence_length) do
    Keyword.put(opts, :compile, batch_size: batch_size, sequence_length: sequence_length)
  end

  defp ml_config(key) do
    case Application.get_env(:foresight, :ml, []) do
      config when is_list(config) -> Keyword.get(config, key)
      config when is_map(config) -> Map.get(config, key)
      _other -> nil
    end
  end
end
