defmodule Foresight.TestSupport.FakeRepo do
  @moduledoc false

  use GenServer

  def child_spec(opts) do
    %{
      id: {__MODULE__, System.unique_integer([:positive])},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    result = Keyword.get(opts, :result, {:ok, %{rows: [[1]]}})

    case Keyword.fetch(opts, :name) do
      {:ok, name} ->
        GenServer.start_link(__MODULE__, %{result: result}, name: name)

      :error ->
        GenServer.start_link(__MODULE__, %{result: result})
    end
  end

  def query(_sql, _params, opts) do
    repo = Keyword.fetch!(opts, :repo)
    GenServer.call(repo, :query)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:query, _from, state), do: {:reply, state.result, state}
end
