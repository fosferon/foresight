defmodule Foresight.Recall.QueryAnalyzer do
  @moduledoc """
  Extracts a temporal constraint (a `%{from: DateTime, to: DateTime}` day/period range)
  from a natural-language query.

  Native port of Hindsight's `DateparserQueryAnalyzer._extract_period`
  (query_analyzer.py:175-294): multilingual *period* expressions in EN/ES/IT/FR/DE
  (yesterday, today, "a few weeks ago", last week/month/year/weekend, "June 2024")
  plus explicit ISO dates. This is the always-available layer.

  The 200+ language single-date tail (incl. Greek) is handled by the Python
  `dateparser` layer which falls back to this module when unavailable.
  """

  @doc """
  Returns a `%{from: DateTime, to: DateTime}` range for the first temporal period
  found in `query`, resolved against `reference` (a `DateTime`), or `nil`.
  """
  @spec analyze(String.t(), DateTime.t(), keyword()) ::
          %{from: DateTime.t(), to: DateTime.t()} | nil
  def analyze(query, reference, opts \\ [])

  def analyze(query, %DateTime{} = reference, opts) when is_binary(query) do
    case analyze_period(query, reference) do
      nil -> analyze_single_date(query, reference, Keyword.get(opts, :dateparser))
      range -> range
    end
  end

  def analyze(_query, _reference, _opts), do: nil

  # Single explicit/absolute date. `dateparser` is an injectable
  # `(query, reference) -> Date.t() | nil` — the Python-worker-backed analyzer in
  # production, a fake in tests, or nil (native periods only). Runs ONLY when the
  # native period layer found nothing, mirroring Hindsight's _extract_period-first order.
  defp analyze_single_date(_query, _reference, nil), do: nil

  defp analyze_single_date(query, %DateTime{} = reference, fun) when is_function(fun, 2) do
    case fun.(query, reference) do
      %Date{} = date -> day(date)
      _ -> nil
    end
  end

  defp analyze_period(query, %DateTime{} = reference) when is_binary(query) do
    ref = DateTime.to_date(reference)

    cond do
      matches?(query, ~r/\b(yesterday|ayer|ieri|hier|gestern)\b/iu) ->
        day(Date.add(ref, -1))

      matches?(query, ~r/\b(today|hoy|oggi|aujourd'?hui|heute)\b/iu) ->
        day(ref)

      # Foresight extras beyond Hindsight's past-focused _extract_period — keep the
      # forward/current-period expressions Foresight already supported (English) so
      # this port is a strict superset, never a regression.
      matches?(query, ~r/\btomorrow\b/iu) ->
        day(Date.add(ref, 1))

      matches?(query, ~r/\bthis\s+week\b/iu) ->
        start = Date.add(ref, -(Date.day_of_week(ref) - 1))
        range(start, Date.add(start, 6))

      matches?(query, ~r/\bthis\s+month\b/iu) ->
        start = %{ref | day: 1}
        range(start, Date.end_of_month(start))

      matches?(query, ~r/\b(a\s+)?couple\s+(of\s+)?days?\s+ago\b/iu) ->
        span(ref, -3, -1)

      matches?(query, ~r/\b(a\s+)?few\s+days?\s+ago\b/iu) ->
        span(ref, -5, -2)

      matches?(query, ~r/\b(a\s+)?couple\s+(of\s+)?weeks?\s+ago\b/iu) ->
        span(ref, -21, -7)

      matches?(query, ~r/\b(a\s+)?few\s+weeks?\s+ago\b/iu) ->
        span(ref, -35, -14)

      matches?(query, ~r/\b(a\s+)?couple\s+(of\s+)?months?\s+ago\b/iu) ->
        span(ref, -90, -30)

      matches?(query, ~r/\b(a\s+)?few\s+months?\s+ago\b/iu) ->
        span(ref, -150, -60)

      matches?(
        query,
        ~r/\b(last\s+week|la\s+semana\s+pasada|la\s+settimana\s+scorsa|la\s+semaine\s+derni[eè]re|letzte\s+woche)\b/iu
      ) ->
        # Monday–Sunday of the prior week. weekday: Mon=0 (Elixir day_of_week - 1).
        start = Date.add(ref, -(Date.day_of_week(ref) - 1 + 7))
        range(start, Date.add(start, 6))

      matches?(
        query,
        ~r/\b(last\s+month|el\s+mes\s+pasado|il\s+mese\s+scorso|le\s+mois\s+dernier|letzten?\s+monat)\b/iu
      ) ->
        last = Date.add(%{ref | day: 1}, -1)
        range(%{last | day: 1}, last)

      matches?(
        query,
        ~r/\b(last\s+year|el\s+a[ñn]o\s+pasado|l'anno\s+scorso|l'ann[ée]e\s+derni[eè]re|letztes?\s+jahr)\b/iu
      ) ->
        y = ref.year - 1
        range(%Date{year: y, month: 1, day: 1}, %Date{year: y, month: 12, day: 31})

      matches?(
        query,
        ~r/\b(last\s+weekend|el\s+fin\s+de\s+semana\s+pasado|lo\s+scorso\s+fine\s+settimana|le\s+week-?end\s+dernier|letztes?\s+wochenende)\b/iu
      ) ->
        # weekday: Mon=0. days since last Saturday (Sat=5), never 0 (always PRIOR).
        days_since_sat = rem(Date.day_of_week(ref) - 1 + 2, 7)
        days_since_sat = if days_since_sat == 0, do: 7, else: days_since_sat
        sat = Date.add(ref, -days_since_sat)
        range(sat, Date.add(sat, 1))

      month_year = month_year(query) ->
        month_year

      iso = explicit_iso(query) ->
        day(iso)

      true ->
        nil
    end
  end

  @months [
    {~r/\b(january|enero|gennaio|janvier|januar)\s+(\d{4})\b/iu, 1},
    {~r/\b(february|febrero|febbraio|f[ée]vrier|februar)\s+(\d{4})\b/iu, 2},
    {~r/\b(march|marzo|mars|m[äa]rz)\s+(\d{4})\b/iu, 3},
    {~r/\b(april|abril|aprile|avril)\s+(\d{4})\b/iu, 4},
    {~r/\b(may|mayo|maggio|mai)\s+(\d{4})\b/iu, 5},
    {~r/\b(june|junio|giugno|juin|juni)\s+(\d{4})\b/iu, 6},
    {~r/\b(july|julio|luglio|juillet|juli)\s+(\d{4})\b/iu, 7},
    {~r/\b(august|agosto|ao[uû]t)\s+(\d{4})\b/iu, 8},
    {~r/\b(september|septiembre|settembre|septembre)\s+(\d{4})\b/iu, 9},
    {~r/\b(october|octubre|ottobre|octobre|oktober)\s+(\d{4})\b/iu, 10},
    {~r/\b(november|noviembre|novembre)\s+(\d{4})\b/iu, 11},
    {~r/\b(december|diciembre|dicembre|d[ée]cembre|dezember)\s+(\d{4})\b/iu, 12}
  ]

  defp month_year(query) do
    Enum.find_value(@months, fn {regex, month} ->
      case Regex.run(regex, query, capture: :all_but_first) do
        [_name, year_str] ->
          year = String.to_integer(year_str)
          start = %Date{year: year, month: month, day: 1}
          range(start, Date.end_of_month(start))

        _ ->
          nil
      end
    end)
  end

  defp explicit_iso(query) do
    case Regex.run(~r/\b(\d{4}-\d{2}-\d{2})\b/, query, capture: :all_but_first) do
      [value] ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp matches?(query, regex), do: Regex.match?(regex, query)

  defp span(ref, from_days, to_days),
    do: range(Date.add(ref, from_days), Date.add(ref, to_days))

  defp day(%Date{} = date), do: range(date, date)

  defp range(%Date{} = from_date, %Date{} = to_date) do
    {:ok, from} = DateTime.new(from_date, ~T[00:00:00], "Etc/UTC")
    {:ok, to} = DateTime.new(to_date, ~T[23:59:59], "Etc/UTC")
    %{from: from, to: to}
  end
end
