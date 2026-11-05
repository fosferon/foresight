defmodule Foresight.TestSupport.FakeOban do
  @moduledoc false

  use GenServer

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {:fake_oban, name},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}
end
