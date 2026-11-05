defmodule Foresight.Jobs.ConsolidateWorkerTest do
  use ExUnit.Case, async: true

  alias Foresight.Jobs.ConsolidateWorker

  test "one consolidation per bank and payload is in flight at a time" do
    unique = Keyword.fetch!(ConsolidateWorker.__opts__(), :unique)

    assert unique[:keys] == [:context, :payload]
    assert unique[:period] == :infinity

    assert Enum.sort(unique[:states]) == [
             :available,
             :executing,
             :retryable,
             :scheduled,
             :suspended
           ]
  end
end
