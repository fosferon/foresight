defmodule Foresight.Evals.Labeling.GoldIngest do
  @moduledoc """
  Relevance-labeling pipeline, gold-ingest step: parse a human-filled gold artifact (see
  `Foresight.Evals.Labeling.GoldSet.to_artifact/2`) into validated, human-sourced label
  attrs ready for `Foresight.Schemas.LabeledPair.changeset/2`.

  Ungraded pairs (blank `"grade"`) are skipped and counted; malformed pairs (grade outside
  0..3, non-numeric grade, unknown split) are collected under `:errors` with their
  `pair_id` rather than silently dropped, so a labeling pass reports exactly what it took
  and what it rejected. Pure: no DB.
  """

  @splits %{"calibration" => :calibration, "test" => :test}
  @grade_scale 0..3

  @type result :: %{
          labels: [map()],
          errors: [%{pair_id: String.t(), reason: atom()}],
          skipped: non_neg_integer()
        }

  @reference_sources [:human, :agent]

  @spec parse(map(), keyword()) :: result()
  def parse(artifact, opts \\ [])

  def parse(%{"bank_id" => bank_id, "pairs" => pairs}, opts) when is_list(pairs) do
    source = Keyword.get(opts, :source, :human)

    unless source in @reference_sources do
      raise ArgumentError,
            "source must be one of #{inspect(@reference_sources)}, got #{inspect(source)}"
    end

    Enum.reduce(pairs, %{labels: [], errors: [], skipped: 0}, fn pair, acc ->
      classify(pair, bank_id, source, acc)
    end)
    |> Map.update!(:labels, &Enum.reverse/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp classify(pair, bank_id, source, acc) do
    cond do
      blank?(pair["grade"]) ->
        Map.update!(acc, :skipped, &(&1 + 1))

      true ->
        with {:ok, grade} <- coerce_grade(pair["grade"]),
             {:ok, split} <- coerce_split(pair["split"]) do
          attrs = %{
            bank_id: bank_id,
            query_ref: pair["query_ref"],
            query_text: pair["query_text"],
            memory_ref: pair["memory_ref"],
            grade: grade,
            source: source,
            split: split
          }

          Map.update!(acc, :labels, &[attrs | &1])
        else
          {:error, reason} ->
            error = %{pair_id: pair["pair_id"], reason: reason}
            Map.update!(acc, :errors, &[error | &1])
        end
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp coerce_grade(grade) when is_integer(grade) do
    if grade in @grade_scale, do: {:ok, grade}, else: {:error, :grade_out_of_range}
  end

  defp coerce_grade(grade) when is_binary(grade) do
    case Integer.parse(String.trim(grade)) do
      {int, ""} -> coerce_grade(int)
      _ -> {:error, :grade_not_numeric}
    end
  end

  defp coerce_grade(_), do: {:error, :grade_not_numeric}

  defp coerce_split(split) do
    case Map.fetch(@splits, split) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_split}
    end
  end
end
