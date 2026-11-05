defmodule Foresight.Recall.QueryAnalyzerTest do
  @moduledoc """
  Native multilingual temporal period extraction, porting Hindsight's
  DateparserQueryAnalyzer._extract_period (query_analyzer.py:175-294). Covers the
  common period expressions in EN/ES/IT/FR/DE + Month-Year + explicit ISO dates —
  a big widening from Foresight's previous English-only-6-substrings extractor.

  (The 200+ language single-date tail — incl. Greek — is handled via Python dateparser.)
  """
  use ExUnit.Case, async: true

  alias Foresight.Recall.QueryAnalyzer

  # Wednesday 2024-06-19 (Python weekday()=2 / Elixir day_of_week=3).
  @ref ~U[2024-06-19 12:00:00Z]

  defp range(from_iso, to_iso) do
    {:ok, from, _} = DateTime.from_iso8601(from_iso)
    {:ok, to, _} = DateTime.from_iso8601(to_iso)
    %{from: from, to: to}
  end

  test "yesterday / today — multilingual" do
    assert QueryAnalyzer.analyze("what did I do yesterday", @ref) ==
             range("2024-06-18T00:00:00Z", "2024-06-18T23:59:59Z")

    # Spanish
    assert QueryAnalyzer.analyze("qué hice ayer", @ref) ==
             range("2024-06-18T00:00:00Z", "2024-06-18T23:59:59Z")

    assert QueryAnalyzer.analyze("what's on today", @ref) ==
             range("2024-06-19T00:00:00Z", "2024-06-19T23:59:59Z")
  end

  test "last week — multilingual (Monday-Sunday of the prior week)" do
    expected = range("2024-06-10T00:00:00Z", "2024-06-16T23:59:59Z")
    assert QueryAnalyzer.analyze("what did I do last week", @ref) == expected
    # German
    assert QueryAnalyzer.analyze("was habe ich letzte woche gemacht", @ref) == expected
  end

  test "last month / last year" do
    assert QueryAnalyzer.analyze("my notes from last month", @ref) ==
             range("2024-05-01T00:00:00Z", "2024-05-31T23:59:59Z")

    assert QueryAnalyzer.analyze("anything from last year", @ref) ==
             range("2023-01-01T00:00:00Z", "2023-12-31T23:59:59Z")
  end

  test "imprecise 'a few weeks ago' yields a range (-5wk .. -2wk)" do
    assert QueryAnalyzer.analyze("I mentioned it a few weeks ago", @ref) ==
             range("2024-05-15T00:00:00Z", "2024-06-05T23:59:59Z")
  end

  test "Month + Year — multilingual month names" do
    expected = range("2024-06-01T00:00:00Z", "2024-06-30T23:59:59Z")
    assert QueryAnalyzer.analyze("what happened in June 2024", @ref) == expected
    # Spanish month name
    assert QueryAnalyzer.analyze("qué pasó en junio 2024", @ref) == expected
  end

  test "explicit ISO date" do
    assert QueryAnalyzer.analyze("events on 2024-03-15 please", @ref) ==
             range("2024-03-15T00:00:00Z", "2024-03-15T23:59:59Z")
  end

  test "Foresight extras (superset over Hindsight): tomorrow / this week / this month" do
    assert QueryAnalyzer.analyze("what's on tomorrow", @ref) ==
             range("2024-06-20T00:00:00Z", "2024-06-20T23:59:59Z")

    # this week = Monday–Sunday of the current week
    assert QueryAnalyzer.analyze("what did I do this week", @ref) ==
             range("2024-06-17T00:00:00Z", "2024-06-23T23:59:59Z")

    assert QueryAnalyzer.analyze("my notes this month", @ref) ==
             range("2024-06-01T00:00:00Z", "2024-06-30T23:59:59Z")
  end

  test "ordering/counting questions carry no date phrase -> nil" do
    assert QueryAnalyzer.analyze("which did I attend first, the workshop or the seminar", @ref) ==
             nil

    assert QueryAnalyzer.analyze("how many days between the two events", @ref) == nil
  end

  # Composition: the injectable dateparser callback (Python-worker-backed in prod)
  # handles the single explicit-date tail after the native period layer.
  test "falls back to the dateparser callback when no native period matches" do
    fake = fn _q, _ref -> ~D[2024-03-15] end

    assert QueryAnalyzer.analyze("events on March 15th 2024", @ref, dateparser: fake) ==
             range("2024-03-15T00:00:00Z", "2024-03-15T23:59:59Z")
  end

  test "native period wins; the dateparser callback is not consulted" do
    fake = fn _q, _ref -> raise "dateparser must not be called when a native period matched" end

    assert QueryAnalyzer.analyze("what did I do yesterday", @ref, dateparser: fake) ==
             range("2024-06-18T00:00:00Z", "2024-06-18T23:59:59Z")
  end

  test "dateparser callback returning nil yields no constraint" do
    assert QueryAnalyzer.analyze("which did I attend first, x or y", @ref,
             dateparser: fn _q, _ref -> nil end
           ) == nil
  end

  test "without a dateparser callback, only native periods are recognised" do
    assert QueryAnalyzer.analyze("events on March 15th 2024", @ref) == nil
  end
end
