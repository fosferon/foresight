defmodule Foresight.Repo.Migrations.ReconcileStory21HeadSchema do
  use Ecto.Migration

  def change do
    alter table(:memory_units) do
      add :occurred_start, :utc_datetime_usec
      add :occurred_end, :utc_datetime_usec
      add :observation_scopes, :map, null: false, default: %{}
      add :text_signals, :text
      add :consolidated_at, :utc_datetime_usec
      add :consolidation_failed_at, :utc_datetime_usec
    end

    create index(:memory_units, [:occurred_start],
             where: "fact_type = 'observation'",
             name: :memory_units_occurred_start_observation_idx
           )

    create index(:memory_units, [:occurred_end],
             where: "fact_type = 'observation'",
             name: :memory_units_occurred_end_observation_idx
           )

    create index(:memory_units, [:mentioned_at],
             where: "fact_type = 'observation'",
             name: :memory_units_mentioned_at_observation_idx
           )

    create index(:memory_units, [:source_memory_ids],
             using: :gin,
             name: :memory_units_source_memory_ids_gin_idx
           )

    alter table(:documents) do
      add :original_text, :text
      add :content_hash, :text
      add :file_storage_key, :text
      add :file_original_name, :text
      add :file_content_type, :text
    end

    create index(:documents, [:content_hash], name: :documents_content_hash_idx)
    create index(:documents, [:file_storage_key], name: :documents_file_storage_key_idx)

    create table(:file_storage, primary_key: false) do
      add :storage_key, :text, primary_key: true
      add :data, :binary, null: false
    end

    create table(:webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bank_id, references(:banks, type: :text, on_delete: :delete_all)
      add :url, :text, null: false
      add :secret, :text
      add :event_types, {:array, :text}, null: false, default: []
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:webhooks, [:bank_id], name: :webhooks_bank_id_idx)

    create table(:audit_log, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :text, null: false
      add :transport, :text, null: false
      add :bank_id, :text
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :request, :map
      add :response, :map
      add :metadata, :map, null: false, default: %{}
    end

    create index(:audit_log, [:action, :started_at], name: :audit_log_action_started_idx)
    create index(:audit_log, [:bank_id, :started_at], name: :audit_log_bank_started_idx)
    create index(:audit_log, [:started_at], name: :audit_log_started_idx)
  end
end
