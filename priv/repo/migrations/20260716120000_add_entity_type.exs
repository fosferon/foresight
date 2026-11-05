defmodule Foresight.Repo.Migrations.AddEntityType do
  use Ecto.Migration

  # Store a type per entity (PERSON, ORG, LOCATION, EVENT, ... ,
  # CONCEPT). Hindsight flattens every LLM-extracted entity to "CONCEPT"
  # (entity_processing.py:32) and has no type column at all, so this is a genuine
  # extension. Nullable; the app writes "CONCEPT" for untyped entities, and pre-existing
  # rows (NULL) are read as CONCEPT. `alter table` is prefix-aware, so the provisioner
  # applies it to each tenant schema automatically.
  def up do
    alter table(:entities) do
      add(:entity_type, :text)
    end
  end

  def down do
    alter table(:entities) do
      remove(:entity_type)
    end
  end
end
