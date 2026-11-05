defmodule Foresight.Rerankers.Passage do
  @moduledoc """
  Builds the text a cross-encoder reranker scores for a candidate.

  Faithful port of Hindsight's `CrossEncoderReranker.rerank` doc_text assembly
  (`engine/search/reranking.py` lines 188-210): layer context and date onto the
  content so the reranker has temporal + contextual signal, not bare text.

      text                                   → "walked the dog"
      context: "diary"                       → "diary: walked the dog"
      occurred_start: 2022-06-05             → "[Date: June 05, 2022 (2022-06-05)] diary: walked the dog"

  Each layer is added only when present; the date (from `occurred_start`) wraps
  the whole thing including context, exactly as the reference does.
  """

  @doc "Assemble the reranker passage for a recall-response candidate map."
  @spec build(map()) :: String.t()
  def build(%{} = candidate) do
    text = to_string(candidate["content"] || "")

    text =
      case candidate["context"] do
        context when is_binary(context) and context != "" -> "#{context}: #{text}"
        _ -> text
      end

    case to_date(candidate["occurred_start"]) do
      nil -> text
      date -> "[Date: #{Calendar.strftime(date, "%B %d, %Y")} (#{Date.to_iso8601(date)})] #{text}"
    end
  end

  def build(_other), do: ""

  defp to_date(value) when is_binary(value) and value != "" do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_date(datetime)

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> nil
        end
    end
  end

  defp to_date(_value), do: nil
end
