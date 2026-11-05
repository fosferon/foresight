defmodule Foresight.ML.EntailmentServing do
  @moduledoc """
  Nx.Serving for the NLI entailment verifier: a `Bumblebee.Text.text_classification`
  serving over a dedicated MNLI cross-encoder. Input is `{premise, hypothesis}` string pairs
  (evidence, clause); output is per-label softmax scores, from which
  `EntailmentVerifiers.Bumblebee` reads the entailment probability.

  Started (like Foresight.ML.RerankerServing) only when the NLI verifier is in use — i.e.
  a `:entailment_serving_name` is configured. Mirrors the reranker serving's structure.
  """

  @default_model_id "cross-encoder/nli-deberta-v3-small"

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [Keyword.put(opts, :name, name)]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    serving = build_classification_serving(opts)
    Nx.Serving.start_link(name: name, serving: serving)
  end

  def build_classification_serving(opts \\ []) do
    model_id = Keyword.get(opts, :model_id, ml_config(:entailment_model_id) || @default_model_id)

    {:ok, model_info} = Bumblebee.load_model({:hf, model_id})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})

    # top_k covers all NLI labels (contradiction/entailment/neutral) so the entailment
    # score is always present; softmax makes the scores calibrated probabilities.
    serving_opts =
      [scores_function: :softmax, top_k: 5]
      |> maybe_put_compile_opts(
        Keyword.get(opts, :batch_size, ml_config(:entailment_batch_size)),
        Keyword.get(opts, :sequence_length, ml_config(:entailment_sequence_length))
      )

    Bumblebee.Text.text_classification(model_info, tokenizer, serving_opts)
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
