defmodule Foresight.Evals.Labeling.LabelStore do
  @moduledoc """
  Persist label attrs (from `GoldIngest` or the judge labeler) into
  labeled_pairs, idempotently. A re-run upserts on the natural key
  `(bank_id, query_ref, memory_ref, source)` rather than duplicating, so a labeling pass can be
  safely resumed or corrected. Invalid rows are collected, not fatal — the batch reports
  what it wrote and what it rejected.
  """

  alias Foresight.Schemas.LabeledPair

  @replaceable [:grade, :judge_model, :split, :query_text, :updated_at]
  @conflict_target [:bank_id, :query_ref, :memory_ref, :source]

  @type result :: %{written: non_neg_integer(), errors: [Ecto.Changeset.t()]}

  @spec write_all([map()], keyword()) :: result()
  def write_all(attrs_list, opts \\ []) do
    repo = Keyword.get(opts, :repo, Foresight.Repo)

    attrs_list
    |> Enum.map(&write_one(repo, &1))
    |> Enum.reduce(%{written: 0, errors: []}, fn
      {:ok, _row}, acc -> Map.update!(acc, :written, &(&1 + 1))
      {:error, changeset}, acc -> Map.update!(acc, :errors, &[changeset | &1])
    end)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  defp write_one(repo, attrs) do
    %LabeledPair{}
    |> LabeledPair.changeset(attrs)
    |> repo.insert(on_conflict: {:replace, @replaceable}, conflict_target: @conflict_target)
  end
end
