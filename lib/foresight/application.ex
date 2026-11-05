defmodule Foresight.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Foresight.Supervisor.start_link([])
  end
end
