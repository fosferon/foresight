defmodule Foresight.Tenancy.TenantKeyCache do
  @moduledoc false

  use GenServer

  @table :foresight_tenant_key_cache

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  def ensure_started!(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Process.whereis(name) do
      nil ->
        case start_link(name: name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end

    ensure_table!()
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table!()
    {:ok, %{}}
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
