defmodule Foresight.Schemas.Bank do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "banks" do
    field(:name, :string)
    field(:mission, :string)
    field(:background, :string)
    field(:disposition, :map, default: %{})
    field(:auto_consolidate, :boolean, default: false)
    field(:config_overrides, :map, default: %{})
    # Pinned by the DB trigger on first embedded write; read-only from the app's
    # perspective (deliberately not cast), enforcing one embedding profile per bank.
    field(:embedding_dim, :integer)
    field(:embedding_model, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bank, attrs) do
    bank
    |> cast(attrs, [
      :id,
      :name,
      :mission,
      :background,
      :disposition,
      :auto_consolidate,
      :config_overrides
    ])
    |> validate_required([:id, :name])
    |> put_default_mission()
  end

  defp put_default_mission(changeset) do
    case get_field(changeset, :mission) do
      nil -> put_change(changeset, :mission, "")
      _mission -> changeset
    end
  end
end
