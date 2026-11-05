defmodule Foresight.Retain.FactExtractionTest do
  @moduledoc """
  Unit tests for retain-time atomic fact extraction. Pure logic with a
  fake LLM — no Postgres — so these run in the default lane.
  """
  use ExUnit.Case, async: true

  alias Foresight.Prompts.Retain.V1, as: Prompt
  alias Foresight.Retain.FactExtraction

  defmodule TwoFactLLM do
    @moduledoc "Splits any input into two canned atomic facts."
    def complete_json_schema(_prompt, _messages, _schema, _opts) do
      {:ok,
       %{
         "facts" => [
           %{
             "what" => "User took the Spanish course",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "event",
             "occurred_start" => "2024-03-01",
             "occurred_end" => "2024-03-01",
             "fact_type" => "assistant",
             "entities" => ["Spanish course", "user"]
           },
           %{
             "what" => "Barcelona has a temperate climate",
             "who" => "N/A",
             "why" => "N/A",
             "fact_kind" => "conversation",
             "fact_type" => "world"
           }
         ]
       }}
    end
  end

  defmodule EmptyLLM do
    def complete_json_schema(_p, _m, _s, _o), do: {:ok, %{"facts" => []}}
  end

  # Counts how many times it is invoked (one call per chunk) and emits a single
  # distinct fact per call so the chunking test can assert call count, total
  # fact count, and preserved order.
  defmodule CountingLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      n = (Process.get(:call_count) || 0) + 1
      Process.put(:call_count, n)

      {:ok,
       %{
         "facts" => [
           %{
             "what" => "fact #{n}",
             "who" => "N/A",
             "why" => "N/A",
             "fact_kind" => "conversation",
             "fact_type" => "world"
           }
         ]
       }}
    end
  end

  # Emits messy entities to exercise normalization: whitespace, duplicates, a
  # blank, and the {"name"/"text" => ...} object shape.
  defmodule MessyEntitiesLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      {:ok,
       %{
         "facts" => [
           %{
             "what" => "User met Emma",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "conversation",
             "fact_type" => "world",
             "entities" => ["  Emma ", "Emma", "", %{"name" => "Negroni"}, %{"text" => "bar"}]
           }
         ]
       }}
    end
  end

  # Emits typed entities: objects carrying a "type" are preserved as
  # {"name","type"} with the type upcased; bare strings and untyped objects stay
  # bare strings (implicitly CONCEPT downstream).
  defmodule TypedEntitiesLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      {:ok,
       %{
         "facts" => [
           %{
             "what" => "Emily married Sarah",
             "who" => "Emily, Sarah",
             "why" => "N/A",
             "fact_kind" => "event",
             "occurred_start" => "2024-06-09",
             "fact_type" => "world",
             "entities" => [
               %{"name" => "Emily", "type" => "person"},
               %{"name" => "Sarah", "type" => "PERSON"},
               "wedding",
               %{"text" => "rooftop garden"}
             ]
           }
         ]
       }}
    end
  end

  # Captures the opts it was called with in the process dictionary so tests can
  # assert on the provider_opts (temperature / max_tokens) the extraction injects.
  defmodule SpyLLM do
    def complete_json_schema(_p, _m, _s, opts) do
      Process.put(:spy_opts, opts)

      {:ok,
       %{
         "facts" => [
           %{
             "what" => "User likes tea",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "conversation",
             "fact_type" => "world"
           }
         ]
       }}
    end
  end

  # An event fact with NO occurred_* dates but a relative expression ("yesterday")
  # in its text — exercises the occurred_start inference from the parent event date.
  defmodule RelativeEventLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      {:ok,
       %{
         "facts" => [
           %{
             "what" => "User went to the gym yesterday",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "event",
             "fact_type" => "assistant"
           }
         ]
       }}
    end
  end

  # An event fact with occurred_start but no occurred_end — exercises the
  # point-event default (occurred_end := occurred_start).
  defmodule StartOnlyEventLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      {:ok,
       %{
         "facts" => [
           %{
             "what" => "User signed the lease",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "event",
             "occurred_start" => "2024-05-01",
             "fact_type" => "assistant"
           }
         ]
       }}
    end
  end

  # Multi-chunk fake: succeeds on every call EXCEPT the 2nd, which errors —
  # simulates a transient per-chunk failure (truncation/connection) mid-session.
  # Guards against a partial chunk failure must not silently drop that
  # chunk's content; the whole session falls back to the blob.
  defmodule PartialFailLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      n = (Process.get(:call_count) || 0) + 1
      Process.put(:call_count, n)

      if n == 2 do
        {:error, :model_unloaded}
      else
        {:ok,
         %{
           "facts" => [
             %{
               "what" => "fact #{n}",
               "who" => "N/A",
               "why" => "N/A",
               "fact_kind" => "conversation",
               "fact_type" => "world"
             }
           ]
         }}
      end
    end
  end

  # Multi-chunk fake: 1st chunk legitimately yields NO significant facts (empty,
  # not an error); later chunks yield a fact. A legitimately-empty chunk must NOT
  # trigger the blob fallback — the other chunks' facts are kept.
  defmodule EmptyThenFactLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      n = (Process.get(:call_count) || 0) + 1
      Process.put(:call_count, n)

      if n == 1 do
        {:ok, %{"facts" => []}}
      else
        {:ok,
         %{
           "facts" => [
             %{
               "what" => "fact #{n}",
               "who" => "N/A",
               "why" => "N/A",
               "fact_kind" => "conversation",
               "fact_type" => "world"
             }
           ]
         }}
      end
    end
  end

  defmodule ErrorLLM do
    def complete_json_schema(_p, _m, _s, _o), do: {:error, :model_unloaded}
  end

  defmodule RaisingLLM do
    def complete_json_schema(_p, _m, _s, _o), do: raise("boom")
  end

  # Emulates an Ollama-served model that wraps valid JSON in ```json fences and
  # adds a trailing comma — the strict structured parse fails, but the raw body
  # is recoverable.
  defmodule FencedJsonLLM do
    def complete_json_schema(_p, _m, _s, _o) do
      raw = """
      ```json
      {
        "facts": [
          {"what": "User likes tea", "who": "user", "why": "N/A", "fact_kind": "conversation", "fact_type": "world"},
        ]
      }
      ```
      """

      {:error, {:structured_output_error, {:invalid_json, %{data: raw}}}}
    end
  end

  @parent %{
    "id" => "session-1",
    "content" => "long session blob with many turns...",
    "context" => "chat",
    "mentioned_at" => "2024-03-15T00:00:00Z",
    "tags" => ["source:longmemeval"],
    "metadata" => %{"has_answer_turns" => [2]}
  }

  defp entity_items(schema),
    do: schema["properties"]["facts"]["items"]["properties"]["entities"]["items"]

  describe "gating (passthrough)" do
    test "nil mode → items unchanged (blob passthrough)" do
      assert FactExtraction.maybe_extract([@parent], mode: nil, llm: TwoFactLLM) == [@parent]
    end

    test "\"none\"/\"off\" mode → passthrough" do
      assert FactExtraction.maybe_extract([@parent], mode: "none", llm: TwoFactLLM) == [@parent]
      assert FactExtraction.maybe_extract([@parent], mode: "off", llm: TwoFactLLM) == [@parent]
    end

    test "mode set but no LLM → passthrough" do
      assert FactExtraction.maybe_extract([@parent], mode: "concise", llm: nil) == [@parent]
    end

    test "enabled?/1 reflects mode+llm" do
      refute FactExtraction.enabled?(mode: nil, llm: TwoFactLLM)
      refute FactExtraction.enabled?(mode: "concise", llm: nil)
      assert FactExtraction.enabled?(mode: "concise", llm: TwoFactLLM)
    end
  end

  describe "extraction" do
    test "one blob → N atomic fact-items inheriting parent provenance" do
      [f1, f2] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: TwoFactLLM)

      # content is the assembled fact text (what | Involving: who), not the blob
      assert f1["content"] == "User took the Spanish course | Involving: user"
      assert f2["content"] == "Barcelona has a temperate climate"

      # CRITICAL: every fact inherits the session's mentioned_at (temporal anchor).
      # A per-fact 10ms offset nudges each later fact so intra-session emission
      # order is stable (fact 0 unchanged, fact 1 +10ms) — same calendar date.
      assert f1["mentioned_at"] == "2024-03-15T00:00:00Z"
      assert f2["mentioned_at"] == "2024-03-15T00:00:00.010Z"

      # provenance inherited
      assert f1["context"] == "chat"
      assert f1["tags"] == ["source:longmemeval"]
      assert f1["metadata"] == %{"has_answer_turns" => [2]}

      # parent id is dropped so facts don't collide on a shared external id
      refute Map.has_key?(f1, "id")
    end

    test "fact_type maps assistant→experience, world→world" do
      [f1, f2] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: TwoFactLLM)
      assert f1["type"] == "experience"
      assert f2["type"] == "world"
    end

    test "event facts carry occurred dates; conversation facts do not" do
      [event, convo] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: TwoFactLLM)

      # date-only values are coerced to start-of-day UTC so the retain pipeline's
      # parse_datetime keeps them
      assert event["occurred_start"] == "2024-03-01T00:00:00Z"
      assert event["occurred_end"] == "2024-03-01T00:00:00Z"
      assert event["occurred_at"] == "2024-03-01T00:00:00Z"

      assert convo["occurred_start"] == nil
      assert convo["occurred_end"] == nil
      refute Map.has_key?(convo, "occurred_at")
    end
  end

  describe "input chunking" do
    test "short content is a single extraction call" do
      Process.put(:call_count, 0)
      FactExtraction.maybe_extract([@parent], mode: "concise", llm: CountingLLM)
      assert Process.get(:call_count) == 1
    end

    test "long content is chunked; facts extracted per chunk, concatenated in order" do
      Process.put(:call_count, 0)

      # ~8800 chars (well over the 3000-char chunk size), split on ". " boundaries.
      long = String.duplicate("This is a sentence about something notable. ", 200)
      parent = Map.put(@parent, "content", long)

      facts = FactExtraction.maybe_extract([parent], mode: "concise", llm: CountingLLM)
      calls = Process.get(:call_count)

      # more than one extraction call happened (the whole blob was NOT sent at once)
      assert calls > 1
      # every chunk's facts are kept: total == sum across chunks
      assert length(facts) == calls
      # order is preserved: fact 1, fact 2, ... fact N
      assert Enum.map(facts, & &1["content"]) == Enum.map(1..calls, &"fact #{&1}")
    end

    test "a JSON conversation array is chunked at turn boundaries" do
      Process.put(:call_count, 0)

      # 120 turn dicts as a JSON array, well over the 3000-char chunk size — the
      # conversation path (parse_conversation → chunk_conversation) must engage.
      turns =
        for i <- 1..120,
            do: %{"role" => "user", "content" => "Turn #{i} says something notable and specific."}

      parent = Map.put(@parent, "content", Jason.encode!(turns))

      facts = FactExtraction.maybe_extract([parent], mode: "concise", llm: CountingLLM)
      calls = Process.get(:call_count)

      assert calls > 1
      assert length(facts) == calls
    end
  end

  describe "partial chunk failure (safe degradation)" do
    test "a chunk ERROR falls back to the whole-item blob (no silent content loss)" do
      Process.put(:call_count, 0)
      long = String.duplicate("This is a sentence about something notable. ", 200)
      parent = Map.put(@parent, "content", long)

      # One chunk errors mid-session. Rather than emit only the surviving chunks'
      # facts (silently dropping the failed chunk's content), the whole session is
      # preserved as the original blob — matching the pre-chunking contract.
      assert FactExtraction.maybe_extract([parent], mode: "concise", llm: PartialFailLLM) ==
               [parent]
    end

    test "a legitimately-empty chunk does NOT trigger blob fallback; other facts kept" do
      Process.put(:call_count, 0)
      long = String.duplicate("This is a sentence about something notable. ", 200)
      parent = Map.put(@parent, "content", long)

      facts = FactExtraction.maybe_extract([parent], mode: "concise", llm: EmptyThenFactLLM)

      # not a blob fallback — real atomized facts came back from the non-empty chunks
      refute facts == [parent]
      assert Enum.all?(facts, &String.starts_with?(&1["content"], "fact "))
    end
  end

  describe "occurred-date fallbacks for events" do
    test "infers occurred_start from a relative expression when the LLM omits it" do
      # @parent mentioned_at is 2024-03-15; "yesterday" resolves to 2024-03-14.
      [f] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: RelativeEventLLM)

      assert f["occurred_start"] == "2024-03-14T00:00:00Z"
      # point event: occurred_end defaults to the inferred occurred_start
      assert f["occurred_end"] == "2024-03-14T00:00:00Z"
      assert f["occurred_at"] == "2024-03-14T00:00:00Z"
    end

    test "defaults occurred_end to occurred_start for a point event" do
      [f] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: StartOnlyEventLLM)

      assert f["occurred_start"] == "2024-05-01T00:00:00Z"
      assert f["occurred_end"] == "2024-05-01T00:00:00Z"
    end

    # Relative-date inference must resolve against the session's
    # WALL-CLOCK date and preserve its UTC offset, matching Hindsight
    # (event_date + timedelta, offset kept). Coercing to UTC first shifts the
    # instant and — for a non-zero offset — can land on the wrong calendar day.
    test "infers against wall-clock date and preserves the session timezone offset" do
      parent = Map.put(@parent, "mentioned_at", "2024-03-15T00:00:00+03:00")
      [f] = FactExtraction.maybe_extract([parent], mode: "concise", llm: RelativeEventLLM)

      # "yesterday" of local 2024-03-15 (+03:00) is 2024-03-14, same offset — NOT
      # 2024-03-13Z (which UTC-normalising the instant would wrongly produce).
      assert f["occurred_start"] == "2024-03-14T00:00:00+03:00"
      assert f["occurred_end"] == "2024-03-14T00:00:00+03:00"
    end
  end

  describe "per-fact temporal offset" do
    test "nudges each later fact's mentioned_at by index*10ms, same calendar date" do
      [f0, f1] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: TwoFactLLM)

      # fact 0 keeps the parent's mentioned_at untouched (zero offset)
      assert f0["mentioned_at"] == "2024-03-15T00:00:00Z"
      # fact 1 gets +10ms, but the date/timezone are identical
      assert f1["mentioned_at"] == "2024-03-15T00:00:00.010Z"
    end
  end

  describe "entity passthrough" do
    test "carries the LLM-extracted entities onto the fact-item" do
      [f1, f2] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: TwoFactLLM)

      # fact 1 declared entities → carried through for materialize_entities
      assert f1["entities"] == ["Spanish course", "user"]
      # fact 2 declared none → empty list (respected, not backfilled by regex)
      assert f2["entities"] == []
    end

    test "normalizes entities: trims, dedups, drops blanks, accepts object shape" do
      [fact] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: MessyEntitiesLLM)
      assert fact["entities"] == ["Emma", "Negroni", "bar"]
    end

    test "preserves entity types: typed objects → {name,type} upcased, others stay strings" do
      [fact] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: TypedEntitiesLLM)

      assert fact["entities"] == [
               %{"name" => "Emily", "type" => "PERSON"},
               %{"name" => "Sarah", "type" => "PERSON"},
               "wedding",
               "rooftop garden"
             ]
    end
  end

  describe "typed extraction schema/prompt (opt-in)" do
    test "default schema keeps bare-string entities (parity)" do
      assert entity_items(Prompt.schema()) == %{"type" => "string"}
    end

    test "typed schema makes entities {name, type} with a type enum" do
      items = entity_items(Prompt.schema(typed_entities: true))
      assert items["type"] == "object"
      assert items["properties"]["name"] == %{"type" => "string"}
      assert items["properties"]["type"]["enum"] == Prompt.entity_types()
      assert "PERSON" in items["properties"]["type"]["enum"]
    end

    test "typed prompt adds the typing instruction; default does not" do
      [%{content: typed_system} | _] = Prompt.messages("x", "2024-01-01", typed_entities: true)
      [%{content: plain_system} | _] = Prompt.messages("x", "2024-01-01", [])

      assert typed_system =~ "PERSON"
      assert typed_system =~ ~s({"name": ..., "type": ...})
      refute plain_system =~ "one of PERSON, ORG"
    end
  end

  describe "safe degradation" do
    test "empty facts → keep the blob (never drop the memory)" do
      assert FactExtraction.maybe_extract([@parent], mode: "concise", llm: EmptyLLM) == [@parent]
    end

    test "LLM error → passthrough" do
      assert FactExtraction.maybe_extract([@parent], mode: "concise", llm: ErrorLLM) == [@parent]
    end

    test "LLM raises → passthrough (extraction never fails a retain)" do
      assert FactExtraction.maybe_extract([@parent], mode: "concise", llm: RaisingLLM) == [
               @parent
             ]
    end

    test "recovers atomic facts from ```json-fenced body with a trailing comma" do
      [fact] = FactExtraction.maybe_extract([@parent], mode: "concise", llm: FencedJsonLLM)
      assert fact["content"] == "User likes tea | Involving: user"
      assert fact["type"] == "world"
      # provenance still inherited on the recovered path
      assert fact["mentioned_at"] == "2024-03-15T00:00:00Z"
    end
  end

  describe "extraction LLM opts (temperature, max_tokens)" do
    test "injects temperature: 0.1 into provider_opts by default" do
      FactExtraction.maybe_extract([@parent], mode: "concise", llm: SpyLLM)
      opts = Process.get(:spy_opts)
      assert Keyword.get(opts[:provider_opts], :temperature) == 0.1
    end

    test "caller-provided temperature is preserved" do
      FactExtraction.maybe_extract([@parent],
        mode: "concise",
        llm: SpyLLM,
        provider_opts: [temperature: 0.7]
      )

      opts = Process.get(:spy_opts)
      assert Keyword.get(opts[:provider_opts], :temperature) == 0.7
    end

    test "injects a default max_tokens into provider_opts" do
      FactExtraction.maybe_extract([@parent], mode: "concise", llm: SpyLLM)
      opts = Process.get(:spy_opts)
      assert Keyword.get(opts[:provider_opts], :max_tokens) == 4096
    end

    test "caller-provided max_tokens is preserved" do
      FactExtraction.maybe_extract([@parent],
        mode: "concise",
        llm: SpyLLM,
        provider_opts: [max_tokens: 512]
      )

      opts = Process.get(:spy_opts)
      assert Keyword.get(opts[:provider_opts], :max_tokens) == 512
    end
  end

  describe "build_fact_text/1" do
    test "assembles what | Involving: who | why, skipping N/A" do
      assert Prompt.build_fact_text(%{"what" => "A", "who" => "N/A", "why" => "N/A"}) == "A"

      assert Prompt.build_fact_text(%{"what" => "A", "who" => "Bob", "why" => "N/A"}) ==
               "A | Involving: Bob"

      assert Prompt.build_fact_text(%{"what" => "A", "who" => "Bob", "why" => "it matters"}) ==
               "A | Involving: Bob | it matters"
    end

    # Hindsight's LIVE assembler keeps a `When: {when}` clause in the
    # stored/embedded fact text (`_extract_facts_from_chunk`, fact_extraction.py
    # ~L1107-1118): what | When: {when} | Involving: {who} | {why}. Foresight had
    # ported the DEAD `ExtractedFact.build_fact_text` Pydantic method, which drops
    # `when` — stripping the date from every fact reflect/recall sees. The date must
    # sit between `what` and `Involving:`, and only when present/non-N/A.
    test "includes When: <when> between what and who when present (parity with live assembler)" do
      assert Prompt.build_fact_text(%{
               "what" => "User visited Paris",
               "when" => "March 2024",
               "who" => "user",
               "why" => "N/A"
             }) == "User visited Paris | When: March 2024 | Involving: user"

      assert Prompt.build_fact_text(%{
               "what" => "A",
               "when" => "Saturday, June 9, 2024",
               "who" => "N/A",
               "why" => "N/A"
             }) == "A | When: Saturday, June 9, 2024"

      # absent / N/A when → no clause (unchanged behaviour)
      assert Prompt.build_fact_text(%{
               "what" => "A",
               "when" => "N/A",
               "who" => "Bob",
               "why" => "N/A"
             }) ==
               "A | Involving: Bob"

      assert Prompt.build_fact_text(%{"what" => "A", "who" => "Bob", "why" => "N/A"}) ==
               "A | Involving: Bob"
    end
  end

  defmodule NotFactsLLM do
    # Valid JSON, wrong shape: used to be the one fallback path with no log and no event.
    def complete_json_schema(_p, _m, _s, _o), do: {:ok, %{"answer" => "forty-two"}}
  end

  defmodule LeakyErrorLLM do
    # A structured-output failure carries the model's attempted output, which is derived
    # from the user's text.
    def complete_json_schema(_p, _m, _s, _o),
      do: {:error, {:invalid_json, ~s({"facts": [{"what": "SECRET-DIAGNOSIS-MARKER"}])}}
  end

  describe "fallback reporting" do
    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:foresight, :retain, :extraction_fallback],
        fn _event, measurements, metadata, _config ->
          send(parent, {:fallback, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      {:ok, ref: ref}
    end

    test "valid JSON that is not a facts list falls back AND emits the fallback event",
         %{ref: ref} do
      assert FactExtraction.maybe_extract([@parent], mode: "concise", llm: NotFactsLLM) ==
               [@parent]

      assert_receive {:fallback, ^ref, %{count: 1},
                      %{
                        reason: {:unexpected_extraction_shape, ["answer"]},
                        reason_kind: "unexpected_extraction_shape",
                        mode: "concise"
                      }}
    end

    test "the warning names the failure kind but never the raw reason", %{ref: ref} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert FactExtraction.maybe_extract([@parent], mode: "concise", llm: LeakyErrorLLM) ==
                   [@parent]
        end)

      assert log =~ "retain fact extraction failed"
      assert log =~ "invalid_json"
      refute log =~ "SECRET-DIAGNOSIS-MARKER"

      # The telemetry handler (in-process, operator-controlled) still gets the raw reason.
      assert_receive {:fallback, ^ref, _measurements, %{reason: {:invalid_json, raw}}}
      assert raw =~ "SECRET-DIAGNOSIS-MARKER"
    end
  end

  describe "deadline and bounded chunk concurrency" do
    defmodule SlowLLM do
      @moduledoc "Sleeps for the forwarded :sleep_ms, then emits one fact naming its chunk."
      def complete_json_schema(prompt, _m, _s, opts) do
        Process.sleep(Keyword.get(opts, :sleep_ms, 0))

        Foresight.Usage.record(%{
          "kind" => "llm",
          "provider" => "fake",
          "model" => "slow",
          "input_tokens" => 1,
          "output_tokens" => 1,
          "total_tokens" => 2
        })

        {:ok,
         %{
           "facts" => [
             %{
               "what" => "Chunk said: " <> String.trim(prompt.content),
               "who" => "N/A",
               "why" => "N/A",
               "fact_kind" => "conversation",
               "fact_type" => "world"
             }
           ]
         }}
      end
    end

    setup do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:foresight, :retain, :extraction_fallback],
        fn _event, measurements, metadata, _config ->
          send(parent, {:fallback, ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
      {:ok, ref: ref}
    end

    test "items not started before the deadline are stored as-is and reported as :deadline",
         %{ref: ref} do
      items = [@parent, Map.put(@parent, "content", "A second session, after the budget")]

      {out, stats} =
        FactExtraction.extract(items,
          mode: "concise",
          llm: SlowLLM,
          sleep_ms: 80,
          deadline_ms: 40
        )

      # The first item's single chunk started inside the budget and finished; the
      # second item was never started.
      assert stats == %{enabled: true, mode: "concise", fallback_items: 1, empty_items: 0}

      assert [
               %{"content" => "Chunk said:" <> _},
               %{"content" => "A second session, after the budget"}
             ] = out

      assert_receive {:fallback, ^ref, %{count: 1},
                      %{reason: :deadline, reason_kind: "deadline", mode: "concise"}}

      refute_receive {:fallback, ^ref, _, _}
    end

    test "no deadline means no deadline fallbacks" do
      {out, stats} = FactExtraction.extract([@parent], mode: "concise", llm: SlowLLM, sleep_ms: 5)
      assert stats.fallback_items == 0
      assert [%{"content" => "Chunk said:" <> _}] = out
    end

    test "chunks of one item extract concurrently, keep their order, and fold usage back" do
      content = "Alpha one. Beta two. Gamma three. Delta four."
      item = Map.put(@parent, "content", content)
      Foresight.Usage.start()

      {elapsed_us, {out, stats}} =
        :timer.tc(fn ->
          FactExtraction.extract([item],
            mode: "concise",
            llm: SlowLLM,
            sleep_ms: 100,
            chunk_size: 12,
            max_concurrency: 8
          )
        end)

      assert stats.fallback_items == 0
      contents = Enum.map(out, & &1["content"])
      chunk_count = length(contents)
      assert chunk_count >= 4

      # Chunk order survives the fan-out: the sentences come back in input order.
      assert contents
             |> Enum.map(fn text ->
               Enum.find_index(~w(Alpha Beta Gamma Delta), &String.contains?(text, &1))
             end)
             |> Enum.reject(&is_nil/1) == [0, 1, 2, 3]

      # The 100 ms calls ran in parallel, not in sequence.
      assert elapsed_us < 350_000,
             "expected concurrent chunk extraction, took #{div(elapsed_us, 1000)} ms"

      # One ledger entry per chunk, recorded inside the tasks, reached the caller's ledger.
      assert length(Foresight.Usage.drain()) == chunk_count
    end

    test "a deadline cuts a concurrent fan-out short with :deadline fallbacks", %{ref: ref} do
      content = "Alpha one. Beta two. Gamma three. Delta four."
      item = Map.put(@parent, "content", content)

      {out, stats} =
        FactExtraction.extract([item],
          mode: "concise",
          llm: SlowLLM,
          sleep_ms: 200,
          chunk_size: 12,
          max_concurrency: 2,
          deadline_ms: 50
        )

      # Any chunk failing blobs the whole item (the existing safe-degradation rule).
      assert stats.fallback_items == 1
      assert out == [item]
      assert_receive {:fallback, ^ref, %{count: 1}, %{reason: :deadline}}
    end
  end

  describe "extract/2 stats" do
    test "disabled extraction reports enabled: false and passes items through" do
      assert {[@parent], %{enabled: false, mode: nil, fallback_items: 0, empty_items: 0}} =
               FactExtraction.extract([@parent], mode: nil, llm: TwoFactLLM)
    end

    test "counts fallback and empty items separately from extracted ones" do
      {items, stats} = FactExtraction.extract([@parent], mode: "concise", llm: TwoFactLLM)
      assert length(items) == 2
      assert stats == %{enabled: true, mode: "concise", fallback_items: 0, empty_items: 0}

      assert {[@parent], %{fallback_items: 1, empty_items: 0}} =
               FactExtraction.extract([@parent], mode: "concise", llm: ErrorLLM)

      assert {[@parent], %{fallback_items: 0, empty_items: 1}} =
               FactExtraction.extract([@parent], mode: "concise", llm: EmptyLLM)
    end
  end
end
