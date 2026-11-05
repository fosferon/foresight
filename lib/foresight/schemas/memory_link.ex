defmodule Foresight.Schemas.MemoryLink do
  @moduledoc """
  A directed edge in the memory graph: `from_unit_id -> to_unit_id`
  with a `link_type` and `weight`, scoped to a bank.

  Retain currently populates `semantic` (pgvector kNN, weight = cosine similarity) and `temporal`
  (event-time proximity, weight = time-decay) edges. `caused_by` and
  `entity` are valid link types but not yet written.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @link_types ~w(semantic temporal caused_by entity supersedes contradicts refines)

  @type t :: %__MODULE__{}

  schema "memory_links" do
    field(:bank_id, :string)
    field(:from_unit_id, :binary_id)
    field(:to_unit_id, :binary_id)
    field(:link_type, :string)
    field(:weight, :float, default: 1.0)
    field(:entity_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @spec link_types() :: [String.t()]
  def link_types, do: @link_types

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:bank_id, :from_unit_id, :to_unit_id, :link_type, :weight, :entity_id])
    |> validate_required([:bank_id, :from_unit_id, :to_unit_id, :link_type, :weight])
    |> validate_inclusion(:link_type, @link_types)
  end
end
