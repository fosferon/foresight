defmodule Foresight.Evals.Labeling.Pipeline do
  @moduledoc """
  Pure orchestration helpers for the relevance-labeling pipeline.

  This module bridges the JSON gold artifact and candidate-pool sidecar to the judge,
  safely prefills only test rows, and computes the bank-scoped calibration trust gate.
  Human-label ingestion and persistence remain separate concerns.
  """

  alias Foresight.Evals.Labeling.Kappa

  @grade_scale 0..3
  @default_kappa_threshold 0.6
  @judge_splits [:calibration, :test, :train]

  @doc """
  Convert every gold-artifact row to the atom-keyed pair shape accepted by `Judge`.

  Calibration and test splits are preserved. Existing human grades are deliberately not
  copied into judge input.
  """
  @spec gold_judge_pairs(map()) :: [map()]
  def gold_judge_pairs(artifact) when is_map(artifact) do
    bank_id = field(artifact, :bank_id)

    artifact
    |> field(:pairs, [])
    |> Enum.map(&judge_pair(&1, bank_id, split(&1)))
  end

  @doc """
  Build the bulk train judge set from a query-pool sidecar.

  Every pair present in the gold artifact is excluded, and duplicate candidates are
  collapsed by `{query_ref, memory_ref}`. All resulting pairs have the `:train` split.
  """
  @spec train_judge_pairs(map(), map()) :: [map()]
  def train_judge_pairs(pool_sidecar, gold_artifact)
      when is_map(pool_sidecar) and is_map(gold_artifact) do
    bank_id = field(pool_sidecar, :bank_id) || field(gold_artifact, :bank_id)

    gold_keys =
      gold_artifact
      |> field(:pairs, [])
      |> Enum.map(&pair_key/1)
      |> MapSet.new()

    pool_sidecar
    |> field(:query_pools, [])
    |> Enum.flat_map(&pool_pairs(&1, bank_id))
    |> Enum.reduce({[], gold_keys}, fn pair, {pairs, seen} ->
      key = pair_key(pair)

      if MapSet.member?(seen, key) do
        {pairs, seen}
      else
        {[pair | pairs], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc """
  Build the complete judge set and retain only the requested splits.

  This supports correction passes that must replace calibration and train labels without
  touching held-out test labels.
  """
  @spec judge_pairs(map(), map(), [atom()]) :: [map()]
  def judge_pairs(pool_sidecar, gold_artifact, splits)
      when is_map(pool_sidecar) and is_map(gold_artifact) and is_list(splits) do
    invalid_splits = splits -- @judge_splits

    if splits == [] or invalid_splits != [] do
      raise ArgumentError,
            "judge splits must be a non-empty subset of #{inspect(@judge_splits)}"
    end

    selected = MapSet.new(splits)

    (gold_judge_pairs(gold_artifact) ++ train_judge_pairs(pool_sidecar, gold_artifact))
    |> Enum.filter(&MapSet.member?(selected, &1.split))
  end

  @doc """
  Prefill successful LLM grades onto test rows without revealing calibration judgements.

  The artifact is otherwise preserved. Test rows with no matching successful label remain
  unchanged. Both a label list and the `%{labels: labels}` result returned by `Judge` are
  accepted.
  """
  @spec prefill_test_artifact(map(), [map()] | %{required(atom() | String.t()) => term()}) ::
          map()
  def prefill_test_artifact(artifact, judge_result) when is_map(judge_result) do
    prefill_test_artifact(artifact, field(judge_result, :labels, []))
  end

  def prefill_test_artifact(artifact, labels) when is_map(artifact) and is_list(labels) do
    bank_id = field(artifact, :bank_id)
    labels_by_pair = successful_labels_by_pair(labels, bank_id)

    rows =
      artifact
      |> field(:pairs, [])
      |> Enum.map(fn row ->
        if split(row) == :test do
          case Map.get(labels_by_pair, scoped_pair_key(row, bank_id)) do
            nil ->
              row

            label ->
              row
              |> put_field(:grade, field(label, :grade))
              |> put_field(:judge_reason, field(label, :judge_reason))
          end
        else
          row
        end
      end)

    put_field(artifact, :pairs, rows)
  end

  @doc """
  Join bank-scoped human and LLM calibration rows and evaluate the quadratic-kappa gate.

  The confusion matrix is a 4x4 nested list whose rows are human grades and columns are
  LLM grades. Undefined kappa always fails the gate.

  Options:

    * `:bank_id` - restrict the report to one bank
    * `:threshold` - pass threshold (default: `0.6`)
  """
  @spec calibration_report([map()], keyword()) :: map()
  def calibration_report(rows, opts \\ []) when is_list(rows) do
    bank_id = Keyword.get(opts, :bank_id)
    threshold = Keyword.get(opts, :threshold, @default_kappa_threshold)

    calibration_rows =
      Enum.filter(rows, fn row ->
        split(row) == :calibration and (is_nil(bank_id) or field(row, :bank_id) == bank_id)
      end)

    reference_source = reference_source!(calibration_rows, opts)
    reference = grade_index(calibration_rows, reference_source)
    llm = grade_index(calibration_rows, :llm)

    pairs =
      for {key, reference_grade} <- reference,
          {:ok, llm_grade} <- [Map.fetch(llm, key)],
          do: {reference_grade, llm_grade}

    result = Kappa.weighted(pairs, weighting: :quadratic)
    passed? = not is_nil(result.kappa) and result.kappa >= threshold

    Map.merge(result, %{
      confusion: confusion_matrix(pairs),
      threshold: threshold,
      passed?: passed?,
      reference_source: reference_source
    })
  end

  # The gate scores the judge against a reference set. That set may be human-graded or
  # independent-agent-graded, and the two are NOT interchangeable as evidence, so the
  # report always names which one it used and never picks silently when both exist.
  defp reference_source!(rows, opts) do
    case Keyword.get(opts, :reference_source) do
      source when source in [:human, :agent] ->
        source

      nil ->
        present = rows |> Enum.map(&source/1) |> MapSet.new()
        human? = MapSet.member?(present, :human)
        agent? = MapSet.member?(present, :agent)

        cond do
          human? and agent? ->
            raise ArgumentError,
                  "calibration rows carry both :human and :agent grades; " <>
                    "pass reference_source: to choose which one the gate scores against"

          agent? ->
            :agent

          true ->
            :human
        end

      other ->
        raise ArgumentError, "reference_source must be :human or :agent, got #{inspect(other)}"
    end
  end

  defp pool_pairs(pool, bank_id) do
    query_ref = field(pool, :query_ref)
    query_text = field(pool, :query_text)

    pool
    |> field(:candidates, [])
    |> Enum.map(fn candidate ->
      %{
        bank_id: bank_id,
        query_ref: query_ref,
        query_text: query_text,
        memory_ref: field(candidate, :memory_ref),
        content: field(candidate, :content),
        context: field(candidate, :context),
        split: :train
      }
    end)
  end

  defp judge_pair(row, bank_id, split) do
    %{
      bank_id: bank_id,
      query_ref: field(row, :query_ref),
      query_text: field(row, :query_text),
      memory_ref: field(row, :memory_ref),
      content: field(row, :content),
      context: field(row, :context),
      split: split
    }
  end

  defp successful_labels_by_pair(labels, default_bank_id) do
    Enum.reduce(labels, %{}, fn label, acc ->
      grade = field(label, :grade)
      label_bank_id = field(label, :bank_id) || default_bank_id

      if grade in @grade_scale and source(label) in [nil, :llm] do
        Map.put_new(acc, scoped_pair_key(label, label_bank_id), label)
      else
        acc
      end
    end)
  end

  defp grade_index(rows, wanted_source) do
    Enum.reduce(rows, %{}, fn row, acc ->
      case {source(row), grade(row)} do
        {^wanted_source, {:ok, grade}} -> Map.put(acc, scoped_pair_key(row), grade)
        _other -> acc
      end
    end)
  end

  defp confusion_matrix(pairs) do
    counts =
      Enum.reduce(pairs, %{}, fn pair, acc ->
        Map.update(acc, pair, 1, &(&1 + 1))
      end)

    for human_grade <- @grade_scale do
      for llm_grade <- @grade_scale do
        Map.get(counts, {human_grade, llm_grade}, 0)
      end
    end
  end

  defp grade(row) do
    case field(row, :grade) do
      grade when grade in @grade_scale ->
        {:ok, grade}

      grade when is_binary(grade) ->
        case Integer.parse(String.trim(grade)) do
          {integer, ""} when integer in @grade_scale -> {:ok, integer}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  defp source(row) do
    case field(row, :source) do
      :human -> :human
      "human" -> :human
      :agent -> :agent
      "agent" -> :agent
      :llm -> :llm
      "llm" -> :llm
      _other -> nil
    end
  end

  defp split(row) do
    case field(row, :split) do
      :calibration -> :calibration
      "calibration" -> :calibration
      :test -> :test
      "test" -> :test
      :train -> :train
      "train" -> :train
      _other -> nil
    end
  end

  defp pair_key(row), do: {field(row, :query_ref), field(row, :memory_ref)}

  defp scoped_pair_key(row, default_bank_id \\ nil) do
    {field(row, :bank_id) || default_bank_id, field(row, :query_ref), field(row, :memory_ref)}
  end

  defp field(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp put_field(map, key, value) do
    string_key = Atom.to_string(key)

    if Map.has_key?(map, key) and not Map.has_key?(map, string_key) do
      Map.put(map, key, value)
    else
      Map.put(map, string_key, value)
    end
  end
end
