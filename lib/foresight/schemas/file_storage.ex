defmodule Foresight.Schemas.FileStorage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:storage_key, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "file_storage" do
    field(:data, :binary)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(file_storage, attrs) do
    file_storage
    |> cast(attrs, [:storage_key, :data])
    |> validate_required([:storage_key, :data])
  end
end
