defmodule Foresight.Prompts.Consolidation.V1 do
  @moduledoc """
  Faithful Elixir port of Hindsight's `engine/consolidation/prompts.py`
  (`build_batch_consolidation_prompt`): the LLM merge contract that turns raw
  facts into consolidated observations via `creates`/`updates`/`deletes`.

  The MISSION defines *what* to track (bank-overridable) and takes priority over
  the PROCESSING RULES when the two conflict. Rules, decision guide, and output
  format are always present.
  """

  # Mirror of Hindsight's `_DEFAULT_MISSION` (prompts.py:4). The dropped
  # "Prefer specifics over abstractions, never generalise" directive materially
  # improves recall against pointed eval questions (a consolidation calibration finding).
  @default_mission "Track every detail: names, numbers, dates, places, and relationships. " <>
                     "Prefer specifics over abstractions, never generalise."

  @mission_priority_note "If anything in this MISSION conflicts with the PROCESSING RULES, " <>
                           "DECISION GUIDE, or OUTPUT FORMAT below, the MISSION takes priority."

  @processing_rules """
  ## PROCESSING RULES

  1. PREFER UPDATE OVER CREATE (when there is something to merge with): if new facts describe the same canonical event, statement, decision, claim, or recurring pattern already covered by an existing observation, UPDATE that observation and attach the new facts as evidence. Do NOT create a near-duplicate sibling. One canonical observation with many source facts is always better than many siblings with one source fact each. Merge aggressively on: same named event, same diagnostic finding, same architectural decision, same recurring claim. **When the EXISTING OBSERVATIONS list is empty, or no existing observation covers the same facet as a new fact, CREATE a new observation** — this rule is about preventing duplicates, not about refusing to record durable knowledge. CREATE is the correct default for any structurally distinct event, claim, or pattern that has no existing match.

  2. ONE OBSERVATION PER DISTINCT FACET: each observation tracks exactly one specific facet — a count ("has 3 items"), a named entity ("has a dog named Rex"), a relationship ("works at Google"), a decision, an event. Never merge different facets into one observation.

  3. MATCH BY ENTITY/FACET, NOT TOPIC: when deciding whether to UPDATE vs CREATE, match on the specific entity or facet. "Sold item X" updates only the X observation. "Now has 5 items" updates only the count observation. Do not update observations about different entities just because they share a general topic.

  4. STATE CHANGES — UPDATE CONCISELY: when a fact changes the state of something ("sold X", "X died", "moved to Y"), UPDATE the matching observation to reflect the current state. Include dates when available. Keep it concise — only information about THAT specific facet. Example: "User owned a dog named Rex who died on March 15, 2025". Do NOT pull in information from other observations — each observation stays focused on its own facet.

  5. CASCADE TO ALL AFFECTED OBSERVATIONS: a state change may affect multiple observations. For example, if entity C is removed from a group, update BOTH the individual observation for C AND any list/group observation that includes C (remove C from the list while keeping all other members intact).

  6. RESOLVE REFERENCES: when a new fact provides a concrete value for a vague placeholder in an existing observation (e.g., "home country" → "Sweden"), UPDATE to embed the resolved value.

  7. PRESERVE HISTORY: observations that record significant events (sold, died, moved, changed) are important history — never DELETE them. Only delete an observation when it is restated identically or truly meaningless. Be very conservative with deletes.

  8. NO COMPUTATION: you do not have the full picture — never calculate, derive, or adjust numeric values. If the user says "I have 2 dogs" and then "I have a dog named Rex", do NOT update the count to 3 — you don't know if Rex is one of the 2 or a new one. If the user says "I sold X", do NOT decrement a count. Only update a count when the user explicitly states a new count. Synthesize and consolidate what was stated, but never do arithmetic or logical deductions.

  9. KEEP DISTINCT TOPICS DISTINCT: do not merge observations about different people, entities, or unrelated topics. Merging is for the same canonical fact recurring — not for related-but-distinct claims.
  """

  @decision_guide """
  ## DECISION GUIDE

  - **Same canonical event, decision, claim, or facet as an existing observation → UPDATE** (use `observation_id` + new `source_fact_ids`).
  - **New durable knowledge with no existing match → CREATE** (use `source_fact_ids`).
  - **Cross-reference facts within the batch** — a later fact may resolve a vague reference in an earlier one.
  - **Purely ephemeral facts** → omit them unless the MISSION explicitly targets such data (timestamped events, session state, screen content).
  """

  @output_section """
  ## OUTPUT FORMAT

  Return a JSON object with three arrays: `creates`, `updates`, `deletes`.

  ### Example 1 — Merging recurring claims into an existing observation

  Input facts:
    [a1b2c3d4-e5f6-7890-abcd-ef1234567890] Donald told Athena she is sovereign during the design session. (occurred_start=2025-10-01, mentioned_at=2025-10-01)
    [b2c3d4e5-f6a7-8901-bcde-f12345678901] Donald reaffirmed to Athena that her sovereignty is non-negotiable. (occurred_start=2025-10-10, mentioned_at=2025-10-10)

  Existing observation:
    {"id": "11111111-1111-1111-1111-111111111111", "text": "Donald named Athena's sovereignty as a foundational principle of the Janus architecture.", "proof_count": 2}

  Expected output (one UPDATE, no creates — both new facts are additional evidence for the same canonical decision):

  {"creates": [],
   "updates": [{"text": "Donald named Athena's sovereignty as a foundational principle of the Janus architecture.", "observation_id": "11111111-1111-1111-1111-111111111111", "source_fact_ids": ["a1b2c3d4-e5f6-7890-abcd-ef1234567890", "b2c3d4e5-f6a7-8901-bcde-f12345678901"]}],
   "deletes": []}

  ### Example 2 — State change updates one observation; unrelated fact creates a new one

  Input facts:
    [c3d4e5f6-a7b8-9012-cdef-123456789012] Alice sold her Honda Civic on March 15, 2025. (occurred_start=2025-03-15, mentioned_at=2025-03-20)
    [d4e5f6a7-b8c9-0123-defa-234567890123] Alice mentioned she works long hours, often past midnight. (occurred_start=2025-03-20, mentioned_at=2025-03-20)

  Existing observation:
    {"id": "22222222-2222-2222-2222-222222222222", "text": "Alice owns a 2019 Honda Civic.", "proof_count": 2}

  Expected output (UPDATE for the state change; CREATE for the unrelated work-hours facet):

  {"creates": [{"text": "Alice works long hours, often past midnight.", "source_fact_ids": ["d4e5f6a7-b8c9-0123-defa-234567890123"]}],
   "updates": [{"text": "Alice owned a 2019 Honda Civic; sold it on March 15, 2025.", "observation_id": "22222222-2222-2222-2222-222222222222", "source_fact_ids": ["c3d4e5f6-a7b8-9012-cdef-123456789012"]}],
   "deletes": []}

  ### Observation text rules

  - Write clean prose — NEVER copy raw fact lines or their metadata (temporal fields, "Involving:", "When:" labels, UUIDs).
  - Parenthesized metadata like `(occurred_start=...)` and pipe-separated labels like `| Involving: ...` are fact formatting — strip them entirely from observation text.
  - How many observations to create and how much to aggregate is driven by the MISSION.

  ### Field rules

  - `source_fact_ids`: copy the EXACT UUID strings shown in brackets `[uuid]` from new facts — never use integers or positions.
  - `observation_id`: copy the EXACT `id` UUID string from existing observations.
  - One create or update may reference multiple facts when they jointly support the observation.
  - **AT MOST ONE UPDATE PER `observation_id`**: if several new facts all update the same existing observation, emit a single `updates` entry that lists all contributing `source_fact_ids` and a single consolidated `text`. Never emit two `updates` entries with the same `observation_id` in one response — they would silently overwrite each other.
  - `deletes`: only when an observation is directly superseded or contradicted by new facts.
  - Do NOT include `tags` — handled automatically.
  - Return `{"creates": [], "updates": [], "deletes": []}` if nothing durable is found.
  """

  @doc """
  Build the system + user messages for a batch consolidation call.

  `mission` is the bank's observations mission (nil → default). `facts_text` and
  `observations_text` are the rendered INPUT sections (see `format_facts/1` and
  `format_observations/1`). `capacity_note` is an optional slot-cap constraint.
  """
  @spec messages(String.t() | nil, String.t(), String.t(), String.t() | nil) :: [map()]
  def messages(mission, facts_text, observations_text, capacity_note \\ nil) do
    system =
      "You are a memory consolidation system. Synthesize new facts into " <>
        "observations, merging with existing observations when appropriate.\n\n" <>
        "## MISSION\n\n#{mission || @default_mission}\n\n" <>
        @mission_priority_note <>
        capacity_section(capacity_note) <>
        "\n\n" <>
        @processing_rules <>
        "\n\n" <>
        input_section(facts_text, observations_text) <>
        "\n\n" <>
        @decision_guide <>
        "\n\n" <>
        @output_section

    [
      %{role: :system, content: system},
      %{
        role: :user,
        content:
          "Consolidate the new facts against the existing observations per the rules above. " <>
            "Return only the JSON object with `creates`, `updates`, and `deletes`."
      }
    ]
  end

  @doc "JSON schema for the creates/updates/deletes response contract."
  @spec schema() :: map()
  def schema(max_creates \\ nil) do
    string = %{"type" => "string"}
    id_array = %{"type" => "array", "items" => string}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "creates" =>
          maybe_max_items(
            %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{"text" => string, "source_fact_ids" => id_array},
                "required" => ["text", "source_fact_ids"]
              }
            },
            max_creates
          ),
        "updates" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "text" => string,
              "observation_id" => string,
              "source_fact_ids" => id_array
            },
            "required" => ["text", "observation_id", "source_fact_ids"]
          }
        },
        "deletes" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"observation_id" => string},
            "required" => ["observation_id"]
          }
        }
      },
      "required" => ["creates", "updates", "deletes"]
    }
  end

  @doc """
  Render new facts as bracketed lines: `[uuid] content (occurred_start=..., mentioned_at=...)`.
  Mirrors the Hindsight fact rendering the `source_fact_ids` rules refer to.
  """
  @spec format_facts([map()]) :: String.t()
  def format_facts([]), do: "(none)"

  def format_facts(units) do
    Enum.map_join(units, "\n", fn unit ->
      meta =
        [
          temporal_kv("occurred_start", field(unit, :occurred_start)),
          temporal_kv("mentioned_at", field(unit, :mentioned_at))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      content = field(unit, :content) || ""
      id = to_string(field(unit, :id))
      if meta == "", do: "[#{id}] #{content}", else: "[#{id}] #{content} (#{meta})"
    end)
  end

  # Struct-and-map-safe field access (%MemoryUnit{} does not implement Access).
  defp field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  @doc "Render pooled existing observations as a JSON array string (empty → \"[]\")."
  @spec format_observations([map()]) :: String.t()
  def format_observations([]), do: "[]"

  def format_observations(observations) do
    observations
    |> Enum.map(fn obs ->
      %{
        "id" => to_string(obs[:id] || obs["id"]),
        "text" => obs[:text] || obs["text"] || obs[:content] || obs["content"] || "",
        "proof_count" => obs[:proof_count] || obs["proof_count"] || 1
      }
      |> put_optional("occurred_start", obs[:occurred_start] || obs["occurred_start"])
      |> put_optional("occurred_end", obs[:occurred_end] || obs["occurred_end"])
      |> put_optional("mentioned_at", obs[:mentioned_at] || obs["mentioned_at"])
      |> put_optional("source_memories", obs[:source_memories] || obs["source_memories"])
    end)
    |> Jason.encode!(pretty: true)
  end

  defp input_section(facts_text, observations_text) do
    """
    ## INPUT

    ### New facts

    #{facts_text}

    ### Existing observations

    JSON array, pooled from recalls across all new facts above. Each entry has:
    - `id`: unique identifier — copy this exactly when issuing an UPDATE or DELETE
    - `text`: the observation content
    - `proof_count`: number of supporting memories
    - `occurred_start` / `occurred_end`: temporal range of source facts
    - `mentioned_at`: when the observation was last reinforced
    - `source_memories`: the supporting facts (text + dates) already merged into this observation

    #{observations_text}
    """
  end

  # Hindsight constrains the response model's `creates` to the remaining slots
  # (consolidator.py:1546) so the cap is enforced at generation, not only by the
  # post-hoc truncation.
  defp maybe_max_items(array_schema, max) when is_integer(max) and max >= 0,
    do: Map.put(array_schema, "maxItems", max)

  defp maybe_max_items(array_schema, _max), do: array_schema

  defp capacity_section(nil), do: ""
  defp capacity_section(""), do: ""

  defp capacity_section(note),
    do: "\n\n## CAPACITY CONSTRAINT\n\n#{note}"

  defp temporal_kv(_key, nil), do: nil
  defp temporal_kv(key, %DateTime{} = dt), do: "#{key}=#{DateTime.to_iso8601(dt)}"
  defp temporal_kv(key, value) when is_binary(value), do: "#{key}=#{value}"
  defp temporal_kv(_key, _value), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, %DateTime{} = dt), do: Map.put(map, key, DateTime.to_iso8601(dt))
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
