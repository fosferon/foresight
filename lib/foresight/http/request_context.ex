defmodule Foresight.HTTP.RequestContext do
  @moduledoc false

  alias Foresight.Context
  alias Foresight.Error

  @default_resolver Foresight.HTTP.RequestContext.DefaultResolver

  def resolve(conn, bank_id) when is_binary(bank_id) do
    http_config =
      conn.private
      |> Map.fetch!(:foresight_config)
      |> Map.fetch!(:http)

    resolver =
      case Map.get(http_config, :tenant_resolver) do
        nil -> @default_resolver
        module -> module
      end

    resolver_opts = Map.get(http_config, :tenant_resolver_opts, [])

    case resolver.resolve(%{conn: conn, bank_id: bank_id}, resolver_opts) do
      {:ok, %Context{} = ctx} ->
        {:ok, %{ctx | bank: bank_id}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:unauthorized, %{message: inspect(reason)})}
    end
  end
end
