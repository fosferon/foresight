defmodule Foresight.Schemas.MemoryUnit do
  @moduledoc """
  The stored unit of memory: a fact, item, or observation belonging to a bank.

  Internal to the storage layer — embedders interact with units through the
  public API and the backend, not this schema directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @fact_types [:world, :experience, :observation]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "memory_units" do
    field(:fact_type, Ecto.Enum, values: @fact_types)
    field(:content, :string)
    field(:context, :string)
    field(:tags, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})
    field(:proof_count, :integer, default: 1)
    field(:source_memory_ids, {:array, :binary_id}, default: [])
    field(:embedded_by, :string)
    field(:embedded_dim, :integer)
    field(:embedding_384, Pgvector.Ecto.Vector)
    field(:embedding_1024, Pgvector.Ecto.Vector)
    field(:embedding_1536, Pgvector.Ecto.Vector)
    # halfvec: pgvector's HNSW index for plain vectors stops at 2000 dimensions.
    field(:embedding_3072, Pgvector.Ecto.HalfVector)
    field(:document_ref, :string)
    field(:source_location, :map)
    field(:occurred_at, :utc_datetime_usec)
    field(:occurred_start, :utc_datetime_usec)
    field(:occurred_end, :utc_datetime_usec)
    field(:mentioned_at, :utc_datetime_usec)
    field(:observation_scopes, :map, default: %{})
    field(:text_signals, :string)
    field(:consolidated_at, :utc_datetime_usec)
    field(:consolidation_failed_at, :utc_datetime_usec)
    # Set when consolidation supersedes/contradicts this observation instead
    # of deleting it. Recall demotes (not drops) superseded units; reflect can flag them.
    field(:superseded_at, :utc_datetime_usec)

    belongs_to(:bank, Foresight.Schemas.Bank)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(memory_unit, attrs) do
    memory_unit
    |> cast(attrs, [
      :bank_id,
      :fact_type,
      :content,
      :context,
      :tags,
      :metadata,
      :proof_count,
      :source_memory_ids,
      :embedded_by,
      :embedded_dim,
      :embedding_384,
      :embedding_1024,
      :embedding_1536,
      :embedding_3072,
      :document_ref,
      :source_location,
      :occurred_at,
      :occurred_start,
      :occurred_end,
      :mentioned_at,
      :observation_scopes,
      :text_signals,
      :consolidated_at,
      :consolidation_failed_at,
      :superseded_at
    ])
    |> validate_required([:bank_id, :fact_type, :content, :context, :embedded_by, :embedded_dim])
    |> validate_number(:embedded_dim, greater_than: 0)
  end
end
