defmodule Foresight.Recall.RerankWindowTest do
  @moduledoc """
  The rerank prefilter shortlist is sized at `2 * recall_budget`,
  matching Hindsight's `rerank_limit = thinking_budget * 2` (memory_engine.py:3294).

  This is the ISOLATED unit that changed. The end-to-end effect (a wider shortlist
  rescuing relevant candidates) is a whole-pipeline property measured at the bench,
  not here — testing this size calc through the full recall pipeline is exactly what
  the fake embedder defeats (it collapses the candidate pool below any window).
  """
  use ExUnit.Case, async: true

  alias Foresight.Recall.RerankWindow

  test "sizes the shortlist at 2x the recall budget (Hindsight rerank_limit = thinking_budget*2)" do
    assert RerankWindow.size(%{}, 300) == 600
    assert RerankWindow.size(%{}, 100) == 200
    assert RerankWindow.size(%{}, 1000) == 2000
  end

  test "an explicit recall_rerank_window override wins over 2x budget" do
    assert RerankWindow.size(%{"recall_rerank_window" => 50}, 300) == 50
    # string-tolerant, like the rest of the recall scalars
    assert RerankWindow.size(%{"recall_rerank_window" => "80"}, 300) == 80
  end

  test "the answer's max_tokens does NOT shrink the shortlist" do
    # A tiny answer cap must not starve the cross-encoder; Hindsight token-filters
    # AFTER reranking, so the shortlist stays 2*budget regardless of max_tokens.
    assert RerankWindow.size(%{"max_tokens" => 8}, 300) == 600
  end

  test "a non-positive or absent override falls back to 2x budget" do
    assert RerankWindow.size(%{"recall_rerank_window" => 0}, 150) == 300
    assert RerankWindow.size(%{"recall_rerank_window" => nil}, 150) == 300
    assert RerankWindow.size(%{"recall_rerank_window" => "not-a-number"}, 150) == 300
  end
end
