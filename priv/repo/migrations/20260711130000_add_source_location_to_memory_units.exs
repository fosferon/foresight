defmodule Foresight.Repo.Migrations.AddSourceLocationToMemoryUnits do
  use Ecto.Migration

  # Provenance substrate: where in its source document a memory came from.
  # A JSONB blob per memory unit — page, section path, element type (paragraph /
  # table / heading / list), and char span — so a specific vector resolves to
  # (document_ref, exact location) → original file, giving auditable proof of an
  # answer's source. Populated by structure-preserving docling ingestion; NULL for
  # memories retained as plain text.
  def change do
    alter table(:memory_units) do
      add :source_location, :map
    end
  end
end
