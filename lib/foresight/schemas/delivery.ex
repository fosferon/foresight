defmodule Foresight.Schemas.Delivery do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "deliveries" do
    field(:bank_id, :string)
    field(:event_type, :string)
    field(:url, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:next_retry_at, :utc_datetime_usec)
    field(:last_error, :string)
    field(:last_response_status, :integer)
    field(:last_response_body, :string)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:payload, :map, default: %{})

    belongs_to(:webhook, Foresight.Schemas.Webhook, define_field: false, type: :binary_id)
    field(:webhook_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :bank_id,
      :event_type,
      :url,
      :status,
      :attempts,
      :next_retry_at,
      :last_error,
      :last_response_status,
      :last_response_body,
      :last_attempt_at,
      :payload,
      :webhook_id
    ])
    |> validate_required([:bank_id, :event_type, :url, :status, :webhook_id])
  end
end
