defmodule Foresight.Repo.Migrations.CreateBanksAndMemoryUnits do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector"

    create table(:banks, primary_key: false) do
      add :id, :text, primary_key: true
      add :name, :text, null: false
      add :mission, :text, null: false, default: ""
      add :background, :text
      add :disposition, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create table(:memory_units, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bank_id, references(:banks, type: :text, on_delete: :delete_all), null: false
      add :fact_type, :text, null: false
      add :content, :text, null: false
      add :context, :text, null: false
      add :embedding_384, :vector, size: 384
      add :embedded_by, :text, null: false
      add :embedded_dim, :integer, null: false
      add :tags, {:array, :text}, null: false, default: []
      add :proof_count, :integer, null: false, default: 1
      add :source_memory_ids, {:array, :uuid}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec
      add :mentioned_at, :utc_datetime_usec
      add :search_tsv, :tsvector,
        generated:
          "ALWAYS AS (to_tsvector('english', coalesce(content, '') || ' ' || coalesce(context, ''))) STORED"

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:memory_units, :memory_units_fact_type_check,
             check: "fact_type IN ('world', 'experience', 'observation')"
           )

    create index(:memory_units, [:bank_id, :fact_type])
    create index(:memory_units, [:bank_id, :inserted_at])
    create index(:memory_units, [:tags], using: :gin)
    create index(:memory_units, [:search_tsv], using: :gin)

    create index(
             :memory_units,
             ["embedding_384 vector_cosine_ops"],
             using: :hnsw,
             options: "m = 16, ef_construction = 64"
           )

    create index(
             :memory_units,
             [:bank_id],
             where: "fact_type = 'world'",
             name: :memory_units_bank_world_idx
           )

    create index(
             :memory_units,
             [:bank_id],
             where: "fact_type = 'experience'",
             name: :memory_units_bank_experience_idx
           )

    create index(
             :memory_units,
             [:bank_id],
             where: "fact_type = 'observation'",
             name: :memory_units_bank_observation_idx
           )
  end
end
