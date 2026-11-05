defmodule Foresight.Schemas.MemoryUnitEntity do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "memory_unit_entities" do
    belongs_to(:memory_unit, Foresight.Schemas.MemoryUnit)
    belongs_to(:entity, Foresight.Schemas.Entity)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:memory_unit_id, :entity_id])
    |> validate_required([:memory_unit_id, :entity_id])
    |> unique_constraint([:memory_unit_id, :entity_id], name: :memory_unit_entities_unique_idx)
  end
end
