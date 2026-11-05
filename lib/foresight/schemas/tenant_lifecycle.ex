defmodule Foresight.Schemas.TenantLifecycle do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:tenant_id, :string, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "tenant_lifecycles" do
    field(:prefix, :string)
    field(:status, :string)
    field(:last_error, :string)
    field(:metadata, :map, default: %{})
    field(:last_provisioned_at, :utc_datetime_usec)
    field(:last_deleted_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(lifecycle, attrs) do
    lifecycle
    |> cast(attrs, [
      :tenant_id,
      :prefix,
      :status,
      :last_error,
      :metadata,
      :last_provisioned_at,
      :last_deleted_at
    ])
    |> validate_required([:tenant_id, :prefix, :status])
  end
end
