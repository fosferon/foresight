defmodule Foresight.Schemas.Entity do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "entities" do
    field(:canonical_name, :string)
    field(:normalized_name, :string)
    field(:entity_type, :string)
    field(:mention_count, :integer, default: 0)
    field(:first_seen, :utc_datetime_usec)
    field(:last_seen, :utc_datetime_usec)

    belongs_to(:bank, Foresight.Schemas.Bank)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :bank_id,
      :canonical_name,
      :normalized_name,
      :entity_type,
      :mention_count,
      :first_seen,
      :last_seen
    ])
    |> validate_required([:bank_id, :canonical_name, :normalized_name])
    |> validate_number(:mention_count, greater_than_or_equal_to: 0)
  end
end
