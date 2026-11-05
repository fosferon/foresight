defmodule Foresight.Schemas.Webhook do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "webhooks" do
    field(:url, :string)
    field(:secret, :string)
    field(:event_types, {:array, :string}, default: [])
    field(:enabled, :boolean, default: true)
    field(:http_config, :map, default: %{})

    belongs_to(:bank, Foresight.Schemas.Bank, references: :id, define_field: false, type: :string)
    field(:bank_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:bank_id, :url, :secret, :event_types, :enabled, :http_config])
    |> validate_required([:url])
    |> validate_delivery_url()
  end

  # SSRF guard: a tenant with webhook-admin rights must not be able to make the
  # server POST to internal targets (cloud metadata, loopback control planes, the
  # private network) and read the response back through the delivery-status API.
  defp validate_delivery_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case classify_url(url) do
        :ok -> []
        {:error, message} -> [url: message]
      end
    end)
  end

  @doc false
  @spec classify_url(String.t()) :: :ok | {:error, String.t()}
  def classify_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "must be an http(s) URL"}

      is_nil(uri.host) or uri.host == "" ->
        {:error, "must include a host"}

      blocked_host?(uri.host) ->
        {:error, "must not target a private, loopback, or link-local address"}

      true ->
        :ok
    end
  end

  def classify_url(_url), do: {:error, "must be a string URL"}

  defp blocked_host?(host) do
    host = String.downcase(host)

    cond do
      host in ["localhost", "ip6-localhost", "ip6-loopback"] -> true
      String.ends_with?(host, ".localhost") -> true
      String.ends_with?(host, ".internal") -> true
      true -> ip_literal_blocked?(host)
    end
  end

  defp ip_literal_blocked?(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> private_address?(address)
      {:error, _} -> false
    end
  end

  # IPv4 loopback/private/link-local + IPv6 loopback/unique-local/link-local.
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_address?({0, 0, 0, 0}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFE80..0xFEBF, do: true

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — re-check the embedded IPv4 so e.g.
  # [::ffff:127.0.0.1] is blocked, not just the canonical loopback.
  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, g7, g8}) do
    private_address?({div(g7, 256), rem(g7, 256), div(g8, 256), rem(g8, 256)})
  end

  defp private_address?(_address), do: false
end
