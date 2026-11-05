defmodule Foresight.Reflect.EntailmentVerifiers.Bumblebee do
  @moduledoc """
  NLI entailment verifier. Scores each (evidence, clause) pair with a
  dedicated MNLI cross-encoder — a calibrated, independent entailment signal, the
  strongest of the three verifier backends, for hosts with the ML headroom (e.g. DGX).

  A clause is supported iff its MAX entailment probability over the cited evidence clears
  `:entailment_nli_threshold` (default 0.5). A clause with no cited evidence is
  unsupported (nothing can entail it).

  The Nx.Serving call is isolated behind a scorer so the aggregation/threshold logic is
  pure and unit-testable; the real model (`Foresight.ML.EntailmentServing`, a
  `Bumblebee.Text.text_classification` NLI serving) runs only under the :ml lane. Faithful
  to the pipeline's ML isolation, an absent/unavailable/erroring serving degrades to
  all-supported — a broken verifier never blocks a reflect answer.

  Scorer contract: `fn [{premise, hypothesis}, ...] -> [entailment_prob_float]`, one prob
  per pair, in order.
  """

  @behaviour Foresight.Reflect.EntailmentVerifier

  require Logger

  @default_threshold 0.5

  @impl true
  def verify([], _evidence, _opts), do: []

  def verify(clauses, evidence, opts) when is_list(clauses) do
    case resolve_scorer(opts) do
      nil ->
        all_supported(clauses)

      scorer ->
        score_clauses(clauses, evidence, scorer, threshold(opts))
    end
  end

  # Group pairs by clause, score them all in one batch, take the max entailment prob per
  # clause. Any failure in the scorer degrades the whole call to all-supported.
  defp score_clauses(clauses, evidence, scorer, threshold) do
    indexed = Enum.with_index(clauses)

    pair_specs =
      for {clause, ci} <- indexed, ev <- evidence, do: {ci, {ev, clause}}

    probs = scorer.(Enum.map(pair_specs, fn {_ci, pair} -> pair end))

    by_clause =
      pair_specs
      |> Enum.zip(probs)
      |> Enum.group_by(fn {{ci, _pair}, _prob} -> ci end, fn {_spec, prob} -> prob end)

    Enum.map(indexed, fn {clause, ci} ->
      max_prob = by_clause |> Map.get(ci, []) |> max_or_zero()
      %{clause: clause, supported?: max_prob >= threshold, score: max_prob}
    end)
  rescue
    error ->
      Logger.warning(
        "NLI entailment scorer failed; treating clauses as supported: #{inspect(error)}"
      )

      all_supported(clauses)
  end

  defp max_or_zero([]), do: 0.0
  defp max_or_zero(probs), do: probs |> Enum.max() |> Kernel.*(1.0)

  defp all_supported(clauses),
    do: Enum.map(clauses, &%{clause: &1, supported?: true, score: 1.0})

  defp threshold(opts) do
    case Keyword.get(opts, :entailment_nli_threshold) do
      t when is_number(t) -> t * 1.0
      _ -> Application.get_env(:foresight, :entailment_nli_threshold, @default_threshold) * 1.0
    end
  end

  # An injected `:nli_scorer` wins (tests, custom backends). Otherwise, build a
  # serving-backed scorer iff a serving name is configured; nil means "cannot verify" →
  # the caller degrades to all-supported.
  defp resolve_scorer(opts) do
    case Keyword.get(opts, :nli_scorer) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        case serving_name(opts) do
          nil -> nil
          name -> fn pairs -> run_serving(name, pairs) end
        end
    end
  end

  defp serving_name(opts) do
    Keyword.get(opts, :entailment_serving_name) ||
      get_in(Application.get_env(:foresight, :ml, []), [:entailment_serving_name])
  end

  # Run the batched NLI serving and pull each pair's entailment probability. Bumblebee's
  # text_classification returns %{predictions: [%{score, label}, ...]}; we take the score
  # of the label whose name denotes entailment (case-insensitive "entail").
  defp run_serving(name, pairs) do
    name
    |> Nx.Serving.batched_run(pairs)
    |> List.wrap()
    |> Enum.map(&entailment_prob/1)
  end

  defp entailment_prob(%{predictions: predictions}) when is_list(predictions) do
    predictions
    |> Enum.find(fn %{label: label} -> label |> to_string() |> String.downcase() =~ "entail" end)
    |> case do
      %{score: score} when is_number(score) -> score * 1.0
      _ -> 0.0
    end
  end

  defp entailment_prob(_other), do: 0.0
end
