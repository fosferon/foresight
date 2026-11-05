defmodule Foresight.Repo.Migrations.AddWebhookDeliveryRuntime do
  use Ecto.Migration

  def change do
    alter table(:webhooks) do
      add :http_config, :map, null: false, default: %{}
    end

    create table(:deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :webhook_id, references(:webhooks, type: :binary_id, on_delete: :delete_all), null: false
      add :bank_id, :text, null: false
      add :event_type, :text, null: false
      add :url, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_retry_at, :utc_datetime_usec
      add :last_error, :text
      add :last_response_status, :integer
      add :last_response_body, :text
      add :last_attempt_at, :utc_datetime_usec
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deliveries, [:webhook_id], name: :deliveries_webhook_id_idx)
    create index(:deliveries, [:bank_id, :inserted_at], name: :deliveries_bank_inserted_idx)
    create index(:deliveries, [:status, :inserted_at], name: :deliveries_status_inserted_idx)
  end
end
