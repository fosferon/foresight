defmodule Foresight.Repo.Migrations.CreateMemoryLinks do
  use Ecto.Migration

  @moduledoc """
  Unit->unit link graph so the recall graph and temporal arms have real
  precomputed structure to expand over.

  Link construction populates `semantic` and `temporal` link_types. `caused_by` and
  `entity` are permitted by the CHECK constraint now so those follow-ups need no
  constraint-widening migration, but nothing writes them yet.
  """

  def change do
    create table(:memory_links, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:bank_id, references(:banks, type: :text, on_delete: :delete_all), null: false)

      add(:from_unit_id, references(:memory_units, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:to_unit_id, references(:memory_units, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:link_type, :text, null: false)
      add(:weight, :float, null: false, default: 1.0)
      # Nullable: only entity-typed links populate this.
      add(:entity_id, references(:entities, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    # Edge uniqueness for the initial link types (entity_id is always NULL here). When
    # entity-typed links land, extend this key to disambiguate multiple entity edges
    # between the same unit pair (Python Hindsight uses a NIL-entity sentinel).
    create(
      unique_index(:memory_links, [:from_unit_id, :to_unit_id, :link_type],
        name: :memory_links_edge_unique_idx
      )
    )

    # Expansion reads seed from either endpoint, ranked by weight per link_type.
    # A btree index is bidirectional, so ascending weight still serves ORDER BY weight DESC.
    create(
      index(:memory_links, [:bank_id, :from_unit_id, :link_type, :weight],
        name: :memory_links_from_type_weight_idx
      )
    )

    create(
      index(:memory_links, [:bank_id, :to_unit_id, :link_type, :weight],
        name: :memory_links_to_type_weight_idx
      )
    )

    create(
      constraint(:memory_links, :memory_links_link_type_check,
        check: "link_type IN ('semantic','temporal','caused_by','entity')"
      )
    )
  end
end
