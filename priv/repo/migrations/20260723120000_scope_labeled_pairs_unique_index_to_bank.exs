defmodule Foresight.Repo.Migrations.ScopeLabeledPairsUniqueIndexToBank do
  use Ecto.Migration

  def change do
    drop(
      unique_index(:labeled_pairs, [:query_ref, :memory_ref, :source],
        name: :labeled_pairs_query_memory_source_idx
      )
    )

    create(
      unique_index(:labeled_pairs, [:bank_id, :query_ref, :memory_ref, :source],
        name: :labeled_pairs_bank_query_memory_source_idx
      )
    )
  end
end
