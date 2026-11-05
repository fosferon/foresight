defmodule Foresight.Recall.SemanticFloor do
  @moduledoc """
  Resolves the cosine-similarity floor the semantic arm applies before it hands
  candidates to fusion. A unit scoring below the floor against the query embedding
  is never a semantic candidate, whatever the recall budget.

  The floor is the per-bank config field `recall_semantic_floor` (default
  `#{0.3}`). It is model-dependent: `BAAI/bge-small-en-v1.5` scores unrelated
  text at roughly 0.33–0.36 cosine and related text at 0.55–0.78, so on that
  model the default admits nearly the whole bank and leaves the reranker to do
  the work, while ~0.45 already sheds off-topic candidates. Measure on your own
  corpus before raising it: a floor above the model's related-text band empties
  the semantic arm.
  """

  @default 0.3

  @doc "The floor used when the bank sets none: `#{@default}`."
  @spec default() :: float()
  def default, do: @default

  @doc """
  Floor for `params`: the bank's `recall_semantic_floor` when it is a number (or a
  numeric string, matching the recall scalar convention) in `[0.0, 1.0]`, otherwise
  `default/0`.
  """
  @spec value(map()) :: float()
  def value(params) when is_map(params) do
    case normalize(Map.get(params, "recall_semantic_floor")) do
      floor when is_float(floor) and floor >= 0.0 and floor <= 1.0 -> floor
      _other -> @default
    end
  end

  def value(_params), do: @default

  defp normalize(value) when is_float(value), do: value
  defp normalize(value) when is_integer(value), do: value * 1.0

  defp normalize(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _other -> nil
    end
  end

  defp normalize(_value), do: nil
end
