defmodule Foresight.Tenancy.TenantSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    runtime_registry = Keyword.fetch!(opts, :runtime_registry)

    Supervisor.start_link(
      __MODULE__,
      Keyword.put(opts, :prefix, prefix),
      name: via_name(runtime_registry, {:tenant_supervisor, prefix})
    )
  end

  @impl true
  def init(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    runtime_registry = Keyword.fetch!(opts, :runtime_registry)

    children = [
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: via_name(runtime_registry, {:tenant_dynamic_supervisor, prefix})}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def via_name(runtime_registry, key), do: {:via, Registry, {runtime_registry, key}}
end
