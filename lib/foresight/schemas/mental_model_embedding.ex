defmodule Foresight.Schemas.MentalModelEmbedding do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:document_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "mental_model_embeddings" do
    field(:bank_id, :string)
    field(:embedded_dim, :integer)
    field(:embedded_model, :string)
    field(:content_hash, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    timestamps(type: :utc_datetime_usec)
  end
end
