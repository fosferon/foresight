defmodule Foresight.Repo.Migrations.CreateDirectives do
  use Ecto.Migration

  def change do
    create table(:directives, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bank_id, references(:banks, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :content, :text, null: false
      add :priority, :integer, null: false, default: 0
      add :is_active, :boolean, null: false, default: true
      add :tags, {:array, :text}, null: false, default: []
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:directives, [:bank_id, :is_active], name: :directives_bank_active_idx)
    create index(:directives, [:tags], using: :gin, name: :directives_tags_gin_idx)
  end
end
