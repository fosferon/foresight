defmodule Foresight.AsyncQueues.ObanTest do
  @moduledoc """
  Note: asking to queue work when there is no queue must be a legible answer, not a
  raw crash.

  Oban.insert/2 raises "unknown registry: Oban.Registry" when the named instance is not
  running, rather than returning the {:error, reason} its call sites already handle. An
  operator who enables a surface without Oban therefore got an ArgumentError out of retain
  — a 500 on the REST face, and on MCP only the rescue stopped it taking the
  session process down with it.
  """
  use ExUnit.Case, async: false

  alias Foresight.AsyncQueues.Oban, as: Queue
  alias Foresight.Context
  alias Foresight.Error

  defp ctx, do: %Context{tenant_id: "default", mode: :mode_a, bank: "probe"}

  test "enqueueing with no Oban running returns :unavailable instead of raising" do
    assert {:error, %Error{reason: :unavailable, detail: detail}} =
             Queue.enqueue_retain(ctx(), %{"items" => [%{"content" => "x"}], "async" => true}, [])

    assert detail.message =~ "enqueue retain"
    # The underlying cause is preserved, so the operator can see WHY rather than only that.
    assert detail.reason =~ "queue_unavailable"
  end

  test "every enqueue entry point fails the same way, not just retain" do
    # A partial fix here would be worse than none: one surface degrading gracefully while
    # another crashes is harder to diagnose than a uniform failure.
    for {fun, payload} <- [
          {:enqueue_consolidate, %{}},
          {:enqueue_embedding_backfill, %{}},
          {:enqueue_refresh_mental_model, %{"mental_model_id" => "m"}},
          {:enqueue_migrate_bank, %{}},
          {:enqueue_probe_bank, %{}}
        ] do
      assert {:error, %Error{reason: :unavailable}} = apply(Queue, fun, [ctx(), payload, []]),
             "#{fun} did not degrade to a structured error"
    end
  end
end
