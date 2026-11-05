defmodule Foresight.Recall.RerankWindow do
  @moduledoc """
  Sizes the rerank prefilter shortlist — how many fused candidates are handed to the
  (expensive) cross-encoder before the final selection.

  Parity with Hindsight's `rerank_limit = thinking_budget * 2` (memory_engine.py:3294):
  rerank the top 2× the resolved recall budget. An explicit `recall_rerank_window`
  override wins.

  Deliberately NOT a function of the answer's `max_tokens`: Hindsight token-filters
  AFTER reranking (its step 5.5), so shrinking this shortlist by the answer cap would
  starve the cross-encoder the same way the pre-seed recall was starved before.
  """

  @doc """
  Shortlist size for `params` given the already-resolved `recall_budget`.

  Returns an explicit `recall_rerank_window` override when present and positive
  (string- or number-typed, matching the recall scalar convention), otherwise
  `recall_budget * 2`.
  """
  @spec size(map(), non_neg_integer()) :: non_neg_integer()
  def size(params, recall_budget) when is_integer(recall_budget) and recall_budget >= 0 do
    case override(Map.get(params, "recall_rerank_window")) do
      explicit when explicit > 0 -> explicit
      _ -> recall_budget * 2
    end
  end

  defp override(value) when is_integer(value), do: value
  defp override(value) when is_float(value), do: trunc(value)

  defp override(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp override(_value), do: 0
end
