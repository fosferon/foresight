defmodule Foresight.Schemas.Directive do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "directives" do
    field(:name, :string)
    field(:content, :string)
    field(:priority, :integer, default: 0)
    field(:is_active, :boolean, default: true)
    field(:tags, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})

    belongs_to(:bank, Foresight.Schemas.Bank)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(directive, attrs) do
    directive
    |> cast(attrs, [:bank_id, :name, :content, :priority, :is_active, :tags, :metadata])
    |> validate_required([:bank_id, :name, :content])
    |> validate_number(:priority, greater_than_or_equal_to: 0)
  end
end
