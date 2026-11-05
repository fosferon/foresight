defmodule Foresight.Evals.DegradationWatchTest do
  @moduledoc """
  The guard that stops a degraded benchmark being scored. It runs in the default lane on
  purpose: the thing it protects (a head-to-head) is an :ml-tagged run that
  takes hours, so if this were only exercised there it would be verified about as often
  as the bug it exists to catch — which is to say, after the damage.
  """
  use ExUnit.Case, async: false

  alias Foresight.Evals.DegradationWatch
  alias Foresight.Retain.FactExtraction

  defmodule FailingLLM do
    @moduledoc false
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:error, %{type: :connection, message: "timeout"}}
  end

  test "a clean run reports clean" do
    watch = DegradationWatch.start()
    counts = DegradationWatch.stop(watch)

    assert counts == %{extraction_fallbacks: 0, merges_skipped: 0}
    assert DegradationWatch.clean?(counts)
  end

  test "counts both degradation kinds, from any process" do
    watch = DegradationWatch.start()

    [extraction, merge] = DegradationWatch.events()

    :telemetry.execute(extraction, %{count: 1}, %{})

    # Fan out, because the eval emits these from Task.async_stream workers and an
    # increment lost across process boundaries would silently under-report.
    1..5
    |> Task.async_stream(fn _ -> :telemetry.execute(merge, %{count: 1, facts: 3}, %{}) end)
    |> Stream.run()

    counts = DegradationWatch.stop(watch)

    assert counts == %{extraction_fallbacks: 1, merges_skipped: 5}
    refute DegradationWatch.clean?(counts)
  end

  test "stops counting once detached, so one eval cannot contaminate the next" do
    watch = DegradationWatch.start()
    [extraction, _merge] = DegradationWatch.events()
    counts = DegradationWatch.stop(watch)

    :telemetry.execute(extraction, %{count: 1}, %{})

    assert counts.extraction_fallbacks == 0
  end

  # The end-to-end half: the unit tests above would pass even if production emitted an
  # event name nobody listens for. This drives the REAL extraction path with an LLM that
  # fails, and asserts the fallback both happens and is observable.
  test "a real extraction failure emits the event the watch listens for" do
    watch = DegradationWatch.start()

    items = [%{"content" => "Alex prefers Hendrick's gin.", "context" => "chat"}]
    result = FactExtraction.maybe_extract(items, mode: "concise", llm: FailingLLM)

    counts = DegradationWatch.stop(watch)

    # The content still survives — degrading rather than failing is the intended
    # behaviour, and is exactly why the benchmark could not see it.
    assert [%{"content" => content}] = result
    assert content =~ "Hendrick's"

    assert counts.extraction_fallbacks == 1,
           "extraction fell back to raw content without emitting; the benchmark guard is blind"

    refute DegradationWatch.clean?(counts)
  end
end
