defmodule Foresight.Schemas.Document do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "documents" do
    field(:external_id, :string)
    field(:title, :string)
    field(:original_text, :string)
    field(:content_hash, :string)
    field(:file_storage_key, :string)
    field(:file_original_name, :string)
    field(:file_content_type, :string)
    field(:tags, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})

    belongs_to(:bank, Foresight.Schemas.Bank)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :bank_id,
      :external_id,
      :title,
      :original_text,
      :content_hash,
      :file_storage_key,
      :file_original_name,
      :file_content_type,
      :tags,
      :metadata
    ])
    |> validate_required([:bank_id, :external_id])
    |> validate_length(:external_id, min: 1)
    |> unique_constraint([:bank_id, :external_id], name: :documents_bank_external_id_idx)
  end
end
