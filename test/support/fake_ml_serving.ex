defmodule Foresight.TestSupport.FakeMLServing do
  @moduledoc false

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {Agent, :start_link, [fn -> opts end, [name: name]]}
    }
  end
end
