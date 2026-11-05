defmodule Foresight.Tenancy.RuntimeSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Foresight.Tenancy.TenantSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(prefix, opts \\ []) when is_binary(prefix) do
    runtime_supervisor = Keyword.get(opts, :runtime_supervisor, __MODULE__)
    runtime_registry = Keyword.fetch!(opts, :runtime_registry)

    case Registry.lookup(runtime_registry, {:tenant_supervisor, prefix}) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        child_spec = {TenantSupervisor, prefix: prefix, runtime_registry: runtime_registry}

        case DynamicSupervisor.start_child(runtime_supervisor, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @spec stop_prefix(String.t(), keyword()) :: :ok
  def stop_prefix(prefix, opts \\ []) when is_binary(prefix) do
    runtime_registry = Keyword.fetch!(opts, :runtime_registry)

    case Registry.lookup(runtime_registry, {:tenant_supervisor, prefix}) do
      [{pid, _value}] ->
        DynamicSupervisor.terminate_child(Keyword.get(opts, :runtime_supervisor, __MODULE__), pid)
        :ok

      [] ->
        :ok
    end
  end
end
