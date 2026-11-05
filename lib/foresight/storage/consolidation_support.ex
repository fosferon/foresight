defmodule Foresight.Storage.ConsolidationSupport do
  @moduledoc false

  import Ecto.Query

  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.MemoryUnit

  def consolidation_payload(payload, reflect_scope_keys_fun)
      when is_function(reflect_scope_keys_fun, 1) do
    %{
      "scope_keys" => reflect_scope_keys_fun.(payload)
    }
  end

  def reflect_scope_keys(payload, requested_scope_keys_fun)
      when is_function(requested_scope_keys_fun, 1) do
    if List.wrap(payload["tags"]) == [] and Map.get(payload, "observation_scopes", %{}) == %{} do
      []
    else
      requested_scope_keys_fun.(%{
        "tag_scopes" => [
          %{
            "tags" => List.wrap(payload["tags"]),
            "observation_scopes" => Map.get(payload, "observation_scopes", %{})
          }
        ]
      })
    end
  end

  def maybe_enqueue_auto_consolidation(
        ctx,
        items,
        repo,
        queue,
        opts,
        scope_key_for_item_fun,
        repo_opts \\ []
      )
      when is_function(scope_key_for_item_fun, 1) do
    case repo.get(Bank, ctx.bank, repo_opts) do
      %Bank{auto_consolidate: true} ->
        _ =
          queue.enqueue_consolidate(
            ctx,
            %{"tag_scopes" => auto_consolidation_scopes(items, scope_key_for_item_fun)},
            opts
          )

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def bank_consolidation_state(repo, bank_id, repo_opts \\ []) do
    last_consolidated_at =
      from(unit in MemoryUnit,
        where: unit.bank_id == ^bank_id and unit.fact_type == :observation,
        select: max(unit.consolidated_at)
      )
      |> repo.one(repo_opts)

    pending_consolidation_query =
      from(unit in MemoryUnit,
        where: unit.bank_id == ^bank_id and unit.fact_type in [:world, :experience]
      )

    pending_consolidation =
      case last_consolidated_at do
        nil ->
          repo.aggregate(pending_consolidation_query, :count, repo_opts)

        consolidated_at ->
          pending_consolidation_query
          |> where([unit], unit.inserted_at > ^consolidated_at)
          |> repo.aggregate(:count, repo_opts)
      end

    %{last_consolidated_at: last_consolidated_at, pending_consolidation: pending_consolidation}
  end

  def observation_freshness(0), do: "up_to_date"
  def observation_freshness(pending) when pending < 10, do: "slightly_stale"
  def observation_freshness(_pending), do: "stale"

  defp auto_consolidation_scopes(items, scope_key_for_item_fun) do
    items
    |> Enum.map(scope_key_for_item_fun)
    |> Enum.uniq()
    |> Enum.map(&%{"scope_key" => &1})
  end
end
