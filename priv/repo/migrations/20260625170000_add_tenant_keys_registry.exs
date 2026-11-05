defmodule Foresight.Repo.Migrations.AddTenantKeysRegistry do
  use Ecto.Migration

  def change do
    create table(:tenant_keys) do
      add(:slug, :string, null: false)
      add(:api_key_hash, :string, null: false)
      add(:role_name, :string, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:tenant_keys, [:slug, :api_key_hash]))
    create(index(:tenant_keys, [:slug]))
  end
end
