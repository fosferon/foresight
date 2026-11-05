defmodule Foresight.Evals.DegradationWatch do
  @moduledoc """
  Counts the ways a retain pipeline silently degrades, so an eval can refuse to score a
  run that was not actually measuring what it claims.

  Both degradations are deliberate resilience behaviours: extraction falls back to storing
  raw content when the LLM fails, and consolidation skips a scope after exhausting its
  retries. Retain still succeeds in both cases, which is right for production and wrong
  for a benchmark — the arm quietly gets worse while everything reports healthy.

  This is not hypothetical. On 2026-08-14 a head-to-head ran with 10 extraction
  fallbacks and 5 skipped merges: the Foresight arm was storing raw blobs instead of
  extracted facts, which is precisely the deficit worth -0.267 answer accuracy (measured in an
  earlier retain-extraction calibration). The harness would have printed a confident scoreboard had it not
  independently run out of wall-clock, and that number would have entered the record.

  Log lines already existed for both. A log line is not a guard, because nothing can
  assert on it.
  """

  @extraction_fallback [:foresight, :retain, :extraction_fallback]
  @merge_skipped [:foresight, :consolidation, :merge_skipped]

  @type t :: %{extraction_fallbacks: non_neg_integer(), merges_skipped: non_neg_integer()}

  @doc "Telemetry events this watches. Public so a test can assert the emitters use them."
  @spec events() :: [[atom()]]
  def events, do: [@extraction_fallback, @merge_skipped]

  @doc """
  Begin counting. Returns a handle for `stop/1`.

  Counters are `:atomics`-backed because the eval fans instances out across tasks, so
  increments arrive from many processes at once.
  """
  @spec start() :: term()
  def start do
    counters = :counters.new(2, [:atomics])
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events(),
        &__MODULE__.handle_event/4,
        counters
      )

    {handler_id, counters}
  end

  @doc "Stop counting and return the totals."
  @spec stop(term()) :: t()
  def stop({handler_id, counters}) do
    :telemetry.detach(handler_id)

    %{
      extraction_fallbacks: :counters.get(counters, 1),
      merges_skipped: :counters.get(counters, 2)
    }
  end

  @doc "True when nothing degraded — the only state in which a run may be scored."
  @spec clean?(t()) :: boolean()
  def clean?(%{extraction_fallbacks: 0, merges_skipped: 0}), do: true
  def clean?(_counts), do: false

  @doc false
  def handle_event(@extraction_fallback, _measurements, _metadata, counters),
    do: :counters.add(counters, 1, 1)

  def handle_event(@merge_skipped, _measurements, _metadata, counters),
    do: :counters.add(counters, 2, 1)
end
