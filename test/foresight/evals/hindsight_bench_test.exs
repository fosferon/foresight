defmodule Foresight.Evals.HindsightBenchTest do
  @moduledoc """
  Unit tests for the PURE core of the Hindsight bench arm: payload
  building and response parsing. The live HTTP orchestration (`generate/2`) talks
  to a running Hindsight authority and is exercised only in the `:ml`/`:eval`
  matched-model lane, not here.

  These pins matter because a silently-wrong payload or a mis-parsed answer would
  make the Foresight-vs-Hindsight scoreboard produce a plausible-but-fake number —
  exactly what the honest-numbers mandate forbids.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.HindsightBench, as: HB

  describe "client/2" do
    test "normalizes a trailing slash on the base url" do
      c = HB.client("http://hindsight.example:8888/", "sk-abc")
      assert c.base_url == "http://hindsight.example:8888"
      assert c.api_key == "sk-abc"
    end

    test "leaves a slashless base url untouched" do
      c = HB.client("http://127.0.0.1:8888", "k")
      assert c.base_url == "http://127.0.0.1:8888"
    end
  end

  describe "retain_body/1" do
    test "wraps memories as ASYNC retain items (worker-driven; HTTP returns instantly)" do
      # Hindsight's synchronous (async:false) retain does not return reliably over HTTP
      # even when the underlying ingestion completes; async + poll pending_operations is
      # the robust pattern (the retain call returns in ~0s, the worker does the work).
      memories = [%{"content" => "a"}, %{"content" => "b"}]
      assert HB.retain_body(memories) == %{"items" => memories, "async" => true}
    end

    test "stringifies non-string metadata VALUES (Hindsight rejects list/int metadata)" do
      # Hindsight's retain schema requires metadata values to be strings; Foresight's
      # LongMemEval items carry `has_answer_turns` as a list of ints. The content and
      # every reflected field must be preserved byte-for-byte — only the metadata
      # value representation changes, so the head-to-head stays fair.
      item = %{
        "content" => "user: hi",
        "tags" => ["source:longmemeval"],
        "metadata" => %{"has_answer_turns" => [0, 4], "n" => 3, "note" => "keep me"}
      }

      %{"items" => [out], "async" => true} = HB.retain_body([item])

      assert out["content"] == "user: hi"
      assert out["tags"] == ["source:longmemeval"]
      assert out["metadata"]["has_answer_turns"] == "[0,4]"
      assert out["metadata"]["n"] == "3"
      assert out["metadata"]["note"] == "keep me"
    end

    test "items without metadata pass through untouched" do
      item = %{"content" => "a", "context" => "chat"}
      assert %{"items" => [^item]} = HB.retain_body([item])
    end
  end

  describe "reflect_body/2" do
    test "includes query_timestamp when present" do
      assert HB.reflect_body("who?", "2024-06-15T12:00:00Z") == %{
               "query" => "who?",
               "query_timestamp" => "2024-06-15T12:00:00Z"
             }
    end

    test "omits query_timestamp when nil" do
      assert HB.reflect_body("who?", nil) == %{"query" => "who?"}
    end
  end

  describe "parse_reflect_answer/1" do
    test "extracts the text field" do
      assert HB.parse_reflect_answer(%{"text" => "the answer"}) == "the answer"
    end

    test "missing text yields empty string (not nil, not a crash)" do
      assert HB.parse_reflect_answer(%{"based_on" => %{}}) == ""
    end

    test "explicit nil text yields empty string" do
      assert HB.parse_reflect_answer(%{"text" => nil}) == ""
    end
  end

  describe "operations_pending?/1 (retain worker progress)" do
    test "true when pending_operations > 0" do
      assert HB.operations_pending?(%{"pending_operations" => 2})
    end

    test "false when pending_operations is 0 (worker done)" do
      refute HB.operations_pending?(%{"pending_operations" => 0})
    end

    test "false when the field is absent" do
      refute HB.operations_pending?(%{"total_nodes" => 5})
    end
  end

  describe "consolidation_pending?/1" do
    test "true when pending_consolidation > 0" do
      assert HB.consolidation_pending?(%{"pending_consolidation" => 3})
    end

    test "false when pending_consolidation is 0" do
      refute HB.consolidation_pending?(%{"pending_consolidation" => 0})
    end

    test "false when the field is absent (nothing to wait on)" do
      refute HB.consolidation_pending?(%{"last_consolidated_at" => "x"})
    end
  end
end
