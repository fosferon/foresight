defmodule Foresight.Repo.Migrations.CreateEntityGraphTables do
  use Ecto.Migration

  def change do
    create table(:entities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bank_id, references(:banks, type: :text, on_delete: :delete_all), null: false
      add :canonical_name, :text, null: false
      add :normalized_name, :text, null: false
      add :mention_count, :integer, null: false, default: 0
      add :first_seen, :utc_datetime_usec
      add :last_seen, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entities, [:bank_id, :normalized_name], name: :entities_bank_normalized_name_idx)
    create index(:entities, [:bank_id, :mention_count])

    create table(:memory_unit_entities, primary_key: false) do
      add :memory_unit_id, references(:memory_units, type: :binary_id, on_delete: :delete_all), null: false
      add :entity_id, references(:entities, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:memory_unit_entities, [:memory_unit_id, :entity_id], name: :memory_unit_entities_unique_idx)
    create index(:memory_unit_entities, [:entity_id])

    create table(:entity_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bank_id, references(:banks, type: :text, on_delete: :delete_all), null: false
      add :source_entity_id, references(:entities, type: :binary_id, on_delete: :delete_all), null: false
      add :target_entity_id, references(:entities, type: :binary_id, on_delete: :delete_all), null: false
      add :link_type, :text, null: false, default: "co_occurrence"
      add :weight, :integer, null: false, default: 1

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entity_links, [:bank_id, :source_entity_id, :target_entity_id, :link_type], name: :entity_links_unique_idx)
    create index(:entity_links, [:bank_id, :link_type])
  end
end
