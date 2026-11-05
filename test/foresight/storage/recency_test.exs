defmodule Foresight.Storage.RecencyTest do
  @moduledoc """
  Unit tests for the recall recency factor. Pure function over an
  item + params, default lane.

  Pins two fidelity properties against Hindsight's `apply_combined_scoring`
  (`search/reranking.py:103`): recency reads `occurred_start` ONLY (nil → neutral
  0.5), and decays over fractional days (seconds/86_400) with the [0.1, 1.0] clamp.
  """
  use ExUnit.Case, async: true

  alias Foresight.Storage.Ecto, as: Store

  @anchor "2024-06-15T12:00:00Z"
  defp params, do: %{"query_timestamp" => @anchor}

  test "sub-day age decays (12h → 1.0 - 0.5/365, not 1.0)" do
    item = %{"occurred_start" => "2024-06-15T00:00:00Z"}
    assert_in_delta Store.recall_recency_factor(item, params()), 1.0 - 0.5 / 365.0, 1.0e-9
  end

  test "age ≥ 365 days clamps to the 0.1 floor" do
    item = %{"occurred_start" => "2023-06-01T12:00:00Z"}
    assert Store.recall_recency_factor(item, params()) == 0.1
  end

  test "future occurred_start does not exceed 1.0 (age floored at 0)" do
    item = %{"occurred_start" => "2024-06-20T12:00:00Z"}
    assert Store.recall_recency_factor(item, params()) == 1.0
  end

  test "nil occurred_start → neutral 0.5" do
    assert Store.recall_recency_factor(%{}, params()) == 0.5
  end

  test "occurred_start ONLY (F2): mentioned_at without occurred_start is neutral 0.5" do
    # Hindsight uses occurred_start only; a conversation fact with just a mention time
    # gets NO recency boost (0.5), not a boost derived from mentioned_at.
    item = %{"mentioned_at" => "2024-06-15T00:00:00Z", "occurred_end" => "2024-06-15T00:00:00Z"}
    assert Store.recall_recency_factor(item, params()) == 0.5
  end
end
