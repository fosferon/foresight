defmodule Foresight.Reflect.MentalModelRanking do
  @moduledoc """
  Lexical relevance ranking + limit for the reflect `search_mental_models` tool
  .

  The fallback behind `Foresight.Reflect.MentalModels.rank/8`: used when the query
  is blank, the bank's embedding profile cannot be resolved, or the query cannot be
  embedded. Ranks by query token overlap over `title`+`original_text` and takes the
  top `limit`; a blank query preserves input order (already external_id-ordered),
  and ties are stable.
  """

  @doc """
  Rank `mental_models` by lexical relevance to `query`, returning the top `limit`.

  Each item may be any struct/map exposing `:title` and `:original_text` (atom or
  string keys). A blank/nil query preserves input order; equal-relevance ties keep
  input order (stable sort).
  """
  @spec rank([map()], String.t() | nil, non_neg_integer()) :: [map()]
  def rank(mental_models, query, limit)
      when is_list(mental_models) and is_integer(limit) and limit >= 0 do
    tokens = tokenize(query)

    if MapSet.size(tokens) == 0 do
      Enum.take(mental_models, limit)
    else
      mental_models
      |> Enum.sort_by(&relevance(&1, tokens), :desc)
      |> Enum.take(limit)
    end
  end

  defp relevance(mental_model, query_tokens) do
    mental_model
    |> searchable_text()
    |> tokenize()
    |> MapSet.intersection(query_tokens)
    |> MapSet.size()
  end

  defp searchable_text(mental_model) do
    "#{field(mental_model, :title)} #{field(mental_model, :original_text)}"
  end

  defp field(mental_model, key) do
    Map.get(mental_model, key) || Map.get(mental_model, to_string(key)) || ""
  end

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> MapSet.new()
  end

  defp tokenize(_text), do: MapSet.new()
end
