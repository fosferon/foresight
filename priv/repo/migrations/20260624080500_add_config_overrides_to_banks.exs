defmodule Foresight.Repo.Migrations.AddConfigOverridesToBanks do
  use Ecto.Migration

  def change do
    alter table(:banks) do
      add(:config_overrides, :map, null: false, default: %{})
    end
  end
end
