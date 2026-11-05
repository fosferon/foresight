defmodule Foresight.Repo.Migrations.CreateDocumentsAndAttachMemoryUnits do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bank_id, references(:banks, type: :text, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :title, :text
      add :tags, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:documents, [:bank_id, :external_id], name: :documents_bank_external_id_idx)
    create index(:documents, [:bank_id, :inserted_at])
    create index(:documents, [:tags], using: :gin)

    alter table(:memory_units) do
      add :document_ref, :text
    end

    create index(:memory_units, [:bank_id, :document_ref])
  end
end
