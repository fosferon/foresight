defmodule Foresight.Schemas.EntityLink do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "entity_links" do
    field(:link_type, :string, default: "co_occurrence")
    field(:weight, :integer, default: 1)
    belongs_to(:source_entity, Foresight.Schemas.Entity)
    belongs_to(:target_entity, Foresight.Schemas.Entity)
    field(:bank_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:bank_id, :source_entity_id, :target_entity_id, :link_type, :weight])
    |> validate_required([:bank_id, :source_entity_id, :target_entity_id, :link_type, :weight])
    |> validate_number(:weight, greater_than: 0)
  end
end
