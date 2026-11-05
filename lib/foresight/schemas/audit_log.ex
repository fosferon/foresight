defmodule Foresight.Schemas.AuditLog do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  schema "audit_log" do
    field(:action, :string)
    field(:transport, :string)
    field(:bank_id, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:request, :map, default: %{})
    field(:response, :map, default: %{})
    field(:metadata, :map, default: %{})
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :action,
      :transport,
      :bank_id,
      :started_at,
      :ended_at,
      :request,
      :response,
      :metadata
    ])
    |> validate_required([:action, :transport, :started_at])
  end
end
