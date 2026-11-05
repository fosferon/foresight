defmodule Foresight.ML.Serving do
  @moduledoc false

  @default_model_id "BAAI/bge-small-en-v1.5"
  @default_output_attribute :hidden_state
  @default_output_pool :mean_pooling
  @default_embedding_processor :l2_norm

  require Logger

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [Keyword.put(opts, :name, name)]},
      # A model-load failure (transient HF outage, cold cache, no network) must not
      # restart-loop the whole tree — the pgvector core does not need HF. Transient +
      # a clean {:error, …} lets the supervisor back off instead of the MatchError
      # that previously exhausted restart intensity and terminated the application.
      restart: :transient
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case build_text_embedding_serving(opts) do
      {:ok, serving} ->
        Nx.Serving.start_link(name: name, serving: serving)

      {:error, reason} ->
        Logger.error("Foresight.ML.Serving failed to load embedding model: #{inspect(reason)}")
        {:error, {:model_load_failed, reason}}
    end
  end

  def build_text_embedding_serving(opts \\ []) do
    model_id = Keyword.get(opts, :model_id, ml_config(:model_id) || @default_model_id)

    output_attribute =
      Keyword.get(
        opts,
        :output_attribute,
        ml_config(:output_attribute) || @default_output_attribute
      )

    output_pool =
      Keyword.get(opts, :output_pool, ml_config(:output_pool) || @default_output_pool)

    embedding_processor =
      Keyword.get(
        opts,
        :embedding_processor,
        ml_config(:embedding_processor) || @default_embedding_processor
      )

    with {:ok, model_info} <- Bumblebee.load_model({:hf, model_id}),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, model_id}) do
      serving_opts =
        [
          output_attribute: output_attribute,
          output_pool: output_pool,
          embedding_processor: embedding_processor
        ]
        |> maybe_put_compile_opts(
          Keyword.get(opts, :batch_size, ml_config(:batch_size)),
          Keyword.get(opts, :sequence_length, ml_config(:sequence_length))
        )

      {:ok, Bumblebee.Text.text_embedding(model_info, tokenizer, serving_opts)}
    end
  rescue
    error -> {:error, error}
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
