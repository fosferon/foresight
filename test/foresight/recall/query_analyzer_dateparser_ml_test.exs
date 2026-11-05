defmodule Foresight.Recall.QueryAnalyzerDateparserMLTest do
  @moduledoc """
  Live Python `dateparser` round-trip through the ML worker — the 200+
  language single-date tail (incl. Greek) that fronts the native period analyzer.
  Tagged :ml (needs the sentence-transformers venv with `dateparser` installed).
  """
  use ExUnit.Case, async: false

  alias Foresight.ML.PythonLocalWorker
  alias Foresight.Recall.QueryAnalyzer

  @moduletag :ml
  @ref "2024-06-19T12:00:00Z"

  setup_all do
    case python_executable() do
      nil ->
        {:ok,
         skip: "Set FORESIGHT_ML_PYTHON (venv with dateparser) to run the dateparser ML lane."}

      python ->
        start_supervised!({PythonLocalWorker, [python_executable: python, preload_models: false]})
        :ok
    end
  end

  test "extracts explicit dates in Greek and English prose/slash formats" do
    assert {:ok, "2024-03-15"} =
             PythonLocalWorker.analyze_query("events on 15 Μαρτίου 2024", @ref)

    assert {:ok, "2024-03-03"} =
             PythonLocalWorker.analyze_query("what happened on March 3rd 2024", @ref)

    assert {:ok, "2024-03-15"} =
             PythonLocalWorker.analyze_query("meeting on 3/15/2024", @ref)
  end

  test "digit-guard: ordering/counting questions extract no spurious date" do
    assert {:ok, none1} =
             PythonLocalWorker.analyze_query(
               "which did I attend first, the workshop or seminar",
               @ref
             )

    assert {:ok, none2} =
             PythonLocalWorker.analyze_query("how many days between the two events", @ref)

    # Python None crosses erlport as :undefined.
    assert none1 in [nil, :undefined]
    assert none2 in [nil, :undefined]
  end

  test "analyzer composes native periods (which win) with the worker dateparser tail" do
    dp = fn query, reference ->
      case PythonLocalWorker.analyze_query(query, DateTime.to_iso8601(reference)) do
        {:ok, iso} when is_binary(iso) -> Date.from_iso8601!(iso)
        _ -> nil
      end
    end

    reference = ~U[2024-06-19 12:00:00Z]

    # Greek explicit date resolved via the worker.
    assert %{from: ~U[2024-03-15 00:00:00Z], to: ~U[2024-03-15 23:59:59Z]} =
             QueryAnalyzer.analyze("notes from 15 Μαρτίου 2024", reference, dateparser: dp)

    # Native period matches first — the worker is never consulted.
    assert %{from: ~U[2024-06-10 00:00:00Z], to: ~U[2024-06-16 23:59:59Z]} =
             QueryAnalyzer.analyze("what did I do last week", reference, dateparser: dp)
  end

  defp python_executable do
    System.get_env("FORESIGHT_ML_PYTHON") ||
      (
        path = Path.expand("~/.cache/foresight-ml-venv/bin/python")
        if File.exists?(path), do: path
      )
  end
end
