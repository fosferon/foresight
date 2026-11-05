defmodule Foresight.Prompts.Retain.V1 do
  @moduledoc """
  Retain-time atomic fact extraction prompt.

  Faithful port of Hindsight's `engine/retain/fact_extraction.py`
  (`_BASE_FACT_EXTRACTION_PROMPT` + `_CONCISE_GUIDELINES` + `_CONCISE_EXAMPLES`)
  and the `ExtractedFact` schema. The LLM reads a single input (a chat session,
  document, or paragraph) plus its Event Date and emits a LIST of atomic facts —
  one input to N discrete memory units — which is the mechanism by which
  cross-session counts, totals, and temporal ordering become answerable at
  reflect time. Without it, retain stores whole-session blobs and reflect has
  nothing structured to aggregate over.

  `build_fact_text/1` mirrors Hindsight's LIVE inline assembler in
  `_extract_facts_from_chunk` (`what` + optional `When: when` + `Involving: who` +
  `why`, joined by ` | `) — NOT the dead `ExtractedFact.build_fact_text` Pydantic
  method, which omits `when` and is never called by the real pipeline.
  """

  @default_mode "concise"

  @base_intro """
  Extract SIGNIFICANT facts from text. Be SELECTIVE - only extract facts worth remembering long-term.

  LANGUAGE: MANDATORY — Detect the language of the input text and produce ALL output in that EXACT same language. You are STRICTLY FORBIDDEN from translating or switching to any other language. Every single word of your output must be in the same language as the input.
  """

  @fact_format """
  ══════════════════════════════════════════════════════════════════════════
  FACT FORMAT - BE CONCISE
  ══════════════════════════════════════════════════════════════════════════

  1. **what**: Core fact - concise but complete (1-2 sentences max)
  2. **when**: Temporal info if mentioned. "N/A" if none. Use day name when known.
  3. **where**: Location if relevant. "N/A" if none.
  4. **who**: People involved with relationships. "N/A" if just general info.
  5. **why**: Context/significance ONLY if important. "N/A" if obvious.

  CONCISENESS: Capture the essence, not every word. One good sentence beats three mediocre ones.

  ══════════════════════════════════════════════════════════════════════════
  COREFERENCE RESOLUTION
  ══════════════════════════════════════════════════════════════════════════

  Link generic references to names when both appear:
  - "my roommate" + "Emily" → use "Emily (user's roommate)"
  - "the manager" + "Sarah" → use "Sarah (the manager)"

  ══════════════════════════════════════════════════════════════════════════
  CLASSIFICATION
  ══════════════════════════════════════════════════════════════════════════

  fact_kind:
  - "event": Specific datable occurrence (set occurred_start/end)
  - "conversation": Ongoing state, preference, trait (no dates)

  fact_type:
  - "world": About other people, external events, general knowledge, objective facts
  - "assistant": First-person actions, experiences, or observations by the speaker/author (e.g., "I changed X", "I discovered Y"). Also includes interactions with the user (requests, recommendations). If the narrator describes something they did, tried, learned, or decided — use "assistant".

  ══════════════════════════════════════════════════════════════════════════
  TEMPORAL HANDLING
  ══════════════════════════════════════════════════════════════════════════

  Use "Event Date" from input as reference for relative dates.
  - CRITICAL: Convert ALL relative temporal expressions to absolute dates in the fact text itself.
    "yesterday" → write the resolved date (e.g. "on November 12, 2024"), NOT the word "yesterday"
    "last night", "this morning", "today", "tonight" → convert to the resolved absolute date
  - For events: set occurred_start AND occurred_end (same for point events)
  - For conversation facts: NO occurred dates

  ══════════════════════════════════════════════════════════════════════════
  ENTITIES
  ══════════════════════════════════════════════════════════════════════════

  Include: people names, organizations, places, key objects, abstract concepts (career, friendship, etc.)
  Always include "user" when fact is about the user.
  """

  @concise_guidelines """
  ══════════════════════════════════════════════════════════════════════════
  SELECTIVITY - CRITICAL (Reduces 90% of unnecessary output)
  ══════════════════════════════════════════════════════════════════════════

  ONLY extract facts that are:
  ✅ Personal info: names, relationships, roles, background
  ✅ Preferences: likes, dislikes, habits, interests (e.g., "Alice likes coffee")
  ✅ Significant events: milestones, decisions, achievements, changes
  ✅ Plans/goals: future intentions, deadlines, commitments
  ✅ Expertise: skills, knowledge, certifications, experience
  ✅ Important context: projects, problems, constraints
  ✅ Sensory/emotional details: feelings, sensations, perceptions that provide context
  ✅ Observations: descriptions of people, places, things with specific details

  DO NOT extract:
  ❌ Generic greetings: "how are you", "hello", pleasantries without substance
  ❌ Pure filler: "thanks", "sounds good", "ok", "got it", "sure"
  ❌ Process chatter: "let me check", "one moment", "I'll look into it"
  ❌ Repeated info: if already stated, don't extract again

  CONSOLIDATE related statements into ONE fact when possible.
  """

  @concise_examples """
  ══════════════════════════════════════════════════════════════════════════
  EXAMPLES (shown in English for illustration; for non-English input, ALL output values MUST be in the input language)
  ══════════════════════════════════════════════════════════════════════════

  Example 1 - Selective extraction (Event Date: June 10, 2024):
  Input: "Hey! How's it going? So I'm planning my wedding - want a small outdoor ceremony. Just got back from Emily's wedding, she married Sarah at a rooftop garden. I grabbed a coffee on the way."

  Output: ONLY 2 facts (skip greetings, weather, coffee):
  1. what="User planning wedding, wants small outdoor ceremony", who="user", why="N/A", entities=["user", "wedding"]
  2. what="Emily married Sarah at rooftop garden", who="Emily (user's friend), Sarah", occurred_start="2024-06-09", entities=["Emily", "Sarah", "wedding"]

  Example 2 - Professional context:
  Input: "Alice has 5 years of Kubernetes experience and holds CKA certification. She's been leading the infrastructure team since March. By the way, she prefers dark roast coffee."

  Output: ONLY 2 facts (skip coffee preference - too trivial):
  1. what="Alice has 5 years Kubernetes experience, CKA certified", who="Alice", entities=["Alice", "Kubernetes", "CKA"]
  2. what="Alice leads infrastructure team since March", who="Alice", entities=["Alice", "infrastructure"]

  ══════════════════════════════════════════════════════════════════════════
  QUALITY OVER QUANTITY
  ══════════════════════════════════════════════════════════════════════════

  Ask: "Would this be useful to recall in 6 months?" If no, skip it.
  """

  @verbatim_guidelines """
  ══════════════════════════════════════════════════════════════════════════
  VERBATIM MODE
  ══════════════════════════════════════════════════════════════════════════

  Preserve the original wording of each distinct statement. Split the input into
  its distinct factual statements WITHOUT rephrasing the `what` beyond what is
  needed to make each statement self-contained. Still resolve coreferences and
  still classify fact_kind / fact_type / temporal fields.
  """

  @doc "Known extraction modes. `nil`/\"none\" disables extraction (passthrough)."
  @spec modes() :: [String.t()]
  def modes, do: ["concise", "verbatim", "custom"]

  @entity_types ["PERSON", "ORG", "LOCATION", "EVENT", "PRODUCT", "CONCEPT"]

  @doc "The default extraction mode when a mode is enabled without a specific value."
  @spec default_mode() :: String.t()
  def default_mode, do: @default_mode

  # When typed extraction is on, tell the model each entity is {name, type} with a
  # type drawn from the enum; otherwise entities are bare strings (unchanged prompt).
  defp entity_typing_section(true) do
    "\nFor each entity, return an object {\"name\": ..., \"type\": ...} where type is one " <>
      "of #{Enum.join(@entity_types, ", ")}. Use CONCEPT when no other type fits.\n"
  end

  defp entity_typing_section(_), do: ""

  @doc """
  Build the system + user messages for one extraction call.

  `input` is the raw content to atomize. `event_date` is the ISO/string date the
  input was mentioned (used to resolve relative temporal expressions). `mission`
  steers what is worth extracting (nil → none). `mode` selects the guideline
  block; `custom_instructions` supplies the guidelines for `"custom"` mode.
  """
  @spec messages(String.t(), String.t() | nil, keyword()) :: [map()]
  def messages(input, event_date, opts \\ []) do
    mode = normalize_mode(opts[:mode])
    mission = opts[:mission]
    custom = opts[:custom_instructions]

    system =
      @base_intro <>
        mission_section(mission) <>
        guidelines(mode, custom) <>
        "\n" <>
        @fact_format <>
        entity_typing_section(opts[:typed_entities]) <>
        examples(mode)

    user =
      "Event Date: #{event_date || "N/A"}\n\n" <>
        "Extract the significant atomic facts from the following input. " <>
        "Return only the JSON object with a `facts` array.\n\n" <>
        "INPUT:\n" <> input

    [%{role: :system, content: system}, %{role: :user, content: user}]
  end

  @doc "Entity types offered to the typed-extraction schema/prompt."
  @spec entity_types() :: [String.t()]
  def entity_types, do: @entity_types

  @doc """
  JSON schema for the `facts` list response contract (mirrors `FactExtractionResponse`).

  Opts:
    * `:typed_entities` — when true, `entities` items are `{name, type}` objects with a
      `type` enum (an extension beyond Hindsight) instead of bare strings. Default false (parity).
  """
  @spec schema(keyword()) :: map()
  def schema(opts \\ []) do
    string = %{"type" => "string"}
    nullable_string = %{"type" => ["string", "null"]}

    entity_items =
      if opts[:typed_entities] do
        %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "name" => string,
            "type" => %{"type" => "string", "enum" => @entity_types}
          },
          "required" => ["name", "type"]
        }
      else
        string
      end

    fact = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "what" => string,
        "when" => string,
        "where" => string,
        "who" => string,
        "why" => string,
        "fact_kind" => %{"type" => "string", "enum" => ["event", "conversation"]},
        "occurred_start" => nullable_string,
        "occurred_end" => nullable_string,
        "fact_type" => %{"type" => "string", "enum" => ["world", "assistant"]},
        "entities" => %{"type" => "array", "items" => entity_items}
      },
      "required" => ["what", "when", "where", "who", "why", "fact_type"]
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"facts" => %{"type" => "array", "items" => fact}},
      "required" => ["facts"]
    }
  end

  @doc """
  Combine an extracted fact's dimensions into one stored fact string.

  Faithful to Hindsight's LIVE assembler in `_extract_facts_from_chunk`
  (fact_extraction.py ~L1107-1118): `what`, then `When: <when>`, then
  `Involving: <who>`, then `why` — each appended only when present and not "N/A",
  joined by ` | `.

  NOTE: this deliberately does NOT mirror the Pydantic `ExtractedFact.build_fact_text`
  method (py ~L166-181), which omits `when`. That method is DEAD CODE in Hindsight —
  the real retain pipeline never calls it and assembles `combined_text` inline WITH
  the `When:` clause. Porting the method dropped the temporal marker from every stored
  fact, starving semantic recall and reflect of dates on temporal/multi-session
  questions. Keep `When:` here.
  """
  @spec build_fact_text(map()) :: String.t()
  def build_fact_text(%{} = fact) do
    what = fact["what"] || fact[:what] || ""
    when_said = fact["when"] || fact[:when]
    who = fact["who"] || fact[:who]
    why = fact["why"] || fact[:why]

    [what]
    |> maybe_append(when_said, fn v -> "When: #{v}" end)
    |> maybe_append(who, fn v -> "Involving: #{v}" end)
    |> maybe_append(why, & &1)
    |> Enum.join(" | ")
  end

  defp maybe_append(parts, value, fun) do
    trimmed = value |> to_string() |> String.trim()

    if trimmed != "" and String.upcase(trimmed) != "N/A" do
      parts ++ [fun.(trimmed)]
    else
      parts
    end
  end

  defp normalize_mode(nil), do: @default_mode

  defp normalize_mode(mode) when is_binary(mode) do
    down = String.downcase(mode)
    if down in modes(), do: down, else: @default_mode
  end

  defp normalize_mode(_other), do: @default_mode

  defp guidelines("verbatim", _custom), do: @verbatim_guidelines
  defp guidelines("custom", custom) when is_binary(custom) and custom != "", do: custom
  defp guidelines("custom", _custom), do: @concise_guidelines
  defp guidelines(_concise, _custom), do: @concise_guidelines

  defp examples("concise"), do: "\n" <> @concise_examples
  defp examples(_other), do: ""

  defp mission_section(nil), do: ""
  defp mission_section(""), do: ""

  defp mission_section(mission) when is_binary(mission) do
    "\n## MISSION\n\n#{mission}\n\n"
  end
end
