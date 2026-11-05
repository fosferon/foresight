defmodule Foresight.Repo.Migrations.CreateLabeledPairs do
  @moduledoc """
  Graded relevance labels for (query, candidate memory) pairs — the
  substrate for learned per-bank fusion weights.

  Candidates are keyed on `memory_ref` (the stable corpus id carried in
  `metadata["eval_id"]`), not `memory_units.id`, so a hand-graded gold set survives
  corpus reloads. One row per (query_ref, memory_ref, source); human + llm rows for the
  same pair coexist so Cohen's kappa can join them on the `:calibration` split.
  """
  use Ecto.Migration

  def change do
    create table(:labeled_pairs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:bank_id, references(:banks, type: :string, on_delete: :delete_all), null: false)
      add(:query_ref, :string, null: false)
      add(:query_text, :text)
      add(:memory_ref, :string, null: false)
      add(:grade, :integer, null: false)
      add(:source, :string, null: false)
      add(:split, :string, null: false)
      add(:judge_model, :string)

      timestamps(type: :utc_datetime_usec)
    end

    # One grade per (pair, source): a source labels a given pair once; human + llm rows
    # for the same pair sit side by side (the join surface for kappa).
    create(
      unique_index(:labeled_pairs, [:query_ref, :memory_ref, :source],
        name: :labeled_pairs_query_memory_source_idx
      )
    )

    # The fusion tuner reads labels per bank + split (train to ascend, test to score, calibration to
    # gate on kappa).
    create(index(:labeled_pairs, [:bank_id, :split]))
  end
end
