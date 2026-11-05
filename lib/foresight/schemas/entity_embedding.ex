defmodule Foresight.Schemas.EntityEmbedding do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:entity_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "entity_embeddings" do
    field(:embedded_dim, :integer)
    field(:embedded_model, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    timestamps(type: :utc_datetime_usec)
  end
end
