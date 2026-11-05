defmodule Foresight.Config.Resolver do
  @moduledoc false

  alias Foresight.Config.Fields
  alias Foresight.Context

  @spec resolve(Context.t(), map(), map()) :: %{config: map(), overrides: map()}
  def resolve(%Context{} = ctx, bank_overrides, runtime_config) do
    global_overrides =
      runtime_config
      |> get_in([:bank_config, :global])
      |> Fields.normalize_layer()

    tenant_overrides =
      runtime_config
      |> get_in([:bank_config, :tenants, ctx.tenant_id])
      |> Fields.normalize_layer()

    bank_overrides = Fields.normalize_layer(bank_overrides)

    config =
      Fields.defaults()
      |> merge_layer(global_overrides)
      |> merge_layer(tenant_overrides)
      |> merge_layer(bank_overrides)

    %{config: config, overrides: compact_tombstones(bank_overrides)}
  end

  @spec apply_updates(map(), map()) :: map()
  def apply_updates(existing_overrides, updates) do
    existing_overrides = Fields.normalize_layer(existing_overrides)
    updates = Fields.normalize_layer(updates)

    Enum.reduce(updates, existing_overrides, fn
      {key, nil}, acc ->
        Map.delete(acc, key)

      {key, %{} = value}, acc ->
        nested =
          acc
          |> Map.get(key, %{})
          |> ensure_map()
          |> merge_layer(value)

        Map.put(acc, key, nested)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
    |> compact_tombstones()
  end

  defp merge_layer(base, layer) when is_map(base) and is_map(layer) do
    Enum.reduce(layer, base, fn
      {_key, nil}, acc ->
        acc

      {key, %{} = value}, acc ->
        nested =
          acc
          |> Map.get(key, %{})
          |> ensure_map()
          |> merge_layer(value)

        Map.put(acc, key, nested)

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp compact_tombstones(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc ->
        acc

      {key, %{} = value}, acc ->
        nested = compact_tombstones(value)

        if nested == %{} do
          Map.put(acc, key, nested)
        else
          Map.put(acc, key, nested)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp ensure_map(%{} = value), do: value
  defp ensure_map(_value), do: %{}
end
