defmodule Foresight.Repo.Migrations.AddAutoConsolidateToBanks do
  use Ecto.Migration

  def change do
    alter table(:banks) do
      add :auto_consolidate, :boolean, null: false, default: false
    end
  end
end
