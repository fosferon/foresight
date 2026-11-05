defmodule Foresight.Repo.Migrations.AddTenantLifecycleLedger do
  use Ecto.Migration

  def change do
    create table(:tenant_lifecycles, primary_key: false) do
      add(:tenant_id, :string, primary_key: true)
      add(:prefix, :string, null: false)
      add(:status, :string, null: false)
      add(:last_error, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:last_provisioned_at, :utc_datetime_usec)
      add(:last_deleted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:tenant_lifecycles, [:prefix]))
  end
end
