defmodule Foresight.Schemas.TenantKey do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "tenant_keys" do
    field(:slug, :string)
    field(:api_key_hash, :string)
    field(:role_name, :string)
    field(:prefix, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tenant_key, attrs) do
    tenant_key
    |> cast(attrs, [:slug, :api_key_hash, :role_name, :prefix])
    |> validate_required([:slug, :api_key_hash, :role_name])
    |> unique_constraint([:slug, :api_key_hash])
  end
end
