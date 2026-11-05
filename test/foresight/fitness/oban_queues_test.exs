defmodule Foresight.Fitness.ObanQueuesTest do
  use ExUnit.Case, async: true

  alias Foresight.Fitness.ObanQueues

  test "every Oban.Worker queue is declared in the resolved config" do
    assert ObanQueues.violations() == []
  end

  test "all seven worker queues are discovered" do
    queues = ObanQueues.declared_queues() |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    assert queues == [
             :foresight_consolidate,
             :foresight_embedding_backfill,
             :foresight_migrate_bank,
             :foresight_probe_bank,
             :foresight_refresh_mental_model,
             :foresight_retain,
             :foresight_webhook_delivery
           ]
  end
end
