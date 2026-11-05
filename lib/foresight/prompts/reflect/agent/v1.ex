defmodule Foresight.Prompts.Reflect.Agent.V1 do
  @moduledoc """
  System prompt for the agentic (tool-calling) reflect loop. Faithful port
  of Hindsight's `engine/reflect/prompts.py` `build_system_prompt_for_tools`.

  The load-bearing sections — Temporal Reasoning, Conflicts & Ambiguity, and
  Showing Your Reasoning (the explicit KEEP/DROP arithmetic) — are the mechanism
  by which cross-session counts/totals are answered correctly, and are ported
  verbatim.
  """

  @default_role "You are a helpful assistant that answers questions strictly from a user's " <>
                  "retrieved memories."

  @doc """
  Build the tool-calling system prompt.

  Options:
    * `:bank_profile` — map with "name"/"mission" (or atom keys)
    * `:directives` — list of directive maps injected as hard rules
    * `:has_mental_models` — whether the bank has any mental models (default false)
    * `:include_observations` — whether search_observations is exposed (default true)
    * `:budget` — "low" | "mid" | "high" | nil
  """
  @spec system_prompt(keyword()) :: String.t()
  def system_prompt(opts \\ []) do
    bank_profile = Keyword.get(opts, :bank_profile, %{})
    directives = Keyword.get(opts, :directives, [])
    has_mm = Keyword.get(opts, :has_mental_models, false)
    include_obs = Keyword.get(opts, :include_observations, true)
    budget = Keyword.get(opts, :budget)
    finish_with_done = Keyword.get(opts, :finish_with_done, false)

    mission = profile_field(bank_profile, "mission")
    role = if is_binary(mission) and mission != "", do: String.trim(mission), else: @default_role

    [
      [
        "CRITICAL: You MUST ONLY use information from retrieved tool results. NEVER make up names, people, events, or entities.",
        ""
      ],
      directives_section(directives),
      [role, "", "Answer the user's question by reasoning over retrieved memories.", ""],
      disposition_section(bank_profile),
      static_reasoning_rules(),
      output_format_rules(finish_with_done),
      hierarchical_retrieval(has_mm, include_obs),
      query_strategy(),
      budget_guidance(budget),
      workflow(has_mm, include_obs)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  # --- verbatim reasoning discipline (the load-bearing port) ------------------

  defp static_reasoning_rules do
    [
      "## LANGUAGE RULE (default - directives take precedence)",
      "- By default, detect the language of the user's question and respond in that SAME language.",
      "- IMPORTANT: The DIRECTIVES section above has HIGHER PRIORITY than this rule.",
      "",
      "## CRITICAL RULES",
      "- ONLY use information from tool results - no external knowledge or guessing",
      "- You SHOULD synthesize, infer, and reason from the retrieved memories",
      "- You MUST search before saying you don't have information",
      "",
      "## How to Reason",
      "- If memories mention someone did an activity, you can infer they likely enjoyed it",
      "- Synthesize a coherent narrative from related memories",
      "- Be a thoughtful interpreter, not just a literal repeater",
      "- When the exact answer isn't stated, use what IS stated to give a best-effort answer AND surface any uncertainty — never invent confidence the data doesn't support.",
      "",
      "## Temporal Reasoning",
      "Every memory and observation carries temporal fields in the JSON tool result:",
      "- `mentioned_at` — when the user retained the fact (always set).",
      "- `occurred_start` / `occurred_end` — when the underlying event happened (optional, set for dated events).",
      "",
      "When facts about the SAME facet conflict — counts, statuses, ownership, location, presence, etc. — the fact with the LATEST `mentioned_at` is authoritative. Later statements SUPERSEDE earlier ones. Do NOT average, sum, or favor an explicitly-dated fact over a more recent one.",
      "",
      "Example: three count facts come back from recall:",
      "  - 'Team has 2 engineers' (mentioned_at=T1)",
      "  - 'Team now has 1 engineer' (mentioned_at=T2, occurred_start=2026-05-25)",
      "  - 'Team has 5 engineers' (mentioned_at=T3)",
      "with T1 < T2 < T3. The current size is 5, not 1. Then apply later events (e.g. someone leaving after T3) on top of that.",
      "",
      "For reconstructing a TIMELINE of events, order by `occurred_start` / `occurred_end` (when things happened), not `mentioned_at` (when they were retained).",
      "",
      "## Conflicts and Ambiguity",
      "Not every retrieval converges on a single answer. Distinguish two cases:",
      "",
      "- RESOLVABLE conflict — the temporal rule above (latest `mentioned_at` wins) cleanly picks a winner. Apply it and move on.",
      "- UNRESOLVABLE ambiguity — the data is internally inconsistent in a way the temporal rule does NOT settle. Examples: a recent aggregate (count, total) is incompatible with the individual entities you can enumerate; two equally-recent facts disagree and no later fact resolves them; events are described but their relative order is unclear.",
      "",
      "When the data is genuinely ambiguous: SAY SO in your answer. Name the conflicting facts. Explain why they can't be reconciled. Give a range or a best-effort interpretation with explicit uncertainty.",
      "",
      "An honest 'the data is inconsistent about X' beats a confident wrong answer. Do NOT pick a value arbitrarily, average conflicting values, or smooth over gaps in confident prose. Acknowledging ambiguity is a successful answer, not a failure mode.",
      "",
      "## Showing Your Reasoning",
      "For any answer that resolves a conflict between facts, applies events on top of a count or status, or settles an ambiguity — show your work in the answer text so a reader can audit it.",
      "",
      "Walk through these steps explicitly:",
      "1. **List the relevant facts in `mentioned_at` order (oldest → newest)**, each with the value it asserts. Use a short bulleted list.",
      "2. **Identify the authoritative fact** under the temporal rule (latest `mentioned_at` for the contested facet). Write its date down.",
      "3. **List candidate events to apply on top** — anything that changes the count, status, or state being asked about. Write each event's date down next to it.",
      "4. **Sanity-check each candidate event against the authoritative date** — for EVERY event from step 3, write a one-line check in the form `<event> (<event_date>) vs authoritative (<authoritative_date>) → BEFORE/AFTER → KEEP/DROP`. If the event is BEFORE or EQUAL to the authoritative date, DROP it: it is already reflected in the authoritative fact, and applying it again is double-counting. This is the single most common mistake — do not skip this step even if you feel confident.",
      "5. **Show the arithmetic or derivation explicitly** using only the KEEP events from step 4 — e.g. 'authoritative count = 5 (at 2025-02-12); kept events: Shadow died (2025-03-12, AFTER); 5 − 1 = 4'.",
      "6. If step 2 or 3 cannot be done cleanly (no clear winner, overlapping timestamps, unclear event order), STOP and surface this as an UNRESOLVABLE ambiguity per the section above — do not fabricate a derivation.",
      "",
      "For simple factual lookups that don't involve conflict or arithmetic, you can answer directly without this scaffolding.",
      "",
      "**Tool result ordering:** `recall()` and `search_observations()` return their arrays sorted by SEMANTIC RELEVANCE to the query, NOT by time. The POSITION of an entry tells you nothing about when it was retained. For any temporal reasoning, IGNORE the position and read the per-entry `mentioned_at` (and `occurred_start` / `occurred_end`).",
      ""
    ]
  end

  # Port of Hindsight's Output-Format block. On the agentic path the answer is
  # delivered via the terminal `done` tool (finish_with_done: true); the fixed /
  # forced-synthesis path (tools-less) answers in plain text.
  defp output_format_rules(finish_with_done) do
    finish =
      if finish_with_done do
        [
          "- When you have gathered enough evidence, FINISH by calling the `done` tool. Do NOT answer in plain text.",
          "- In `done`, pass your answer as `answer`, and cite EXACTLY the ids you actually used in `memory_ids` / `observation_ids` / `mental_model_ids` — no more, no less. Never cite an id you did not retrieve."
        ]
      else
        [
          "- Answer directly. NEVER ask the user follow-up questions, offer further assistance, or suggest next steps — just answer what was asked."
        ]
      end

    [
      "## Output Format",
      finish,
      "- NEVER include memory IDs, UUIDs, tool names, or internal identifiers in your answer text.",
      "- Do not describe your tool usage or that you 'searched memories' — state the answer.",
      "- Use clean markdown; keep paragraphs readable.",
      ""
    ]
    |> List.flatten()
  end

  # --- tool-adaptive sections -------------------------------------------------

  defp hierarchical_retrieval(has_mm, include_obs) do
    levels =
      [
        has_mm &&
          {"MENTAL MODELS (search_mental_models)",
           [
             "- User-curated summaries about specific topics",
             "- HIGHEST quality - manually created and maintained",
             "- If a relevant mental model exists and is FRESH, it may fully answer the question",
             "- Check `is_stale` field - if stale, also verify with lower levels"
           ]},
        include_obs &&
          {"OBSERVATIONS (search_observations)",
           [
             "- Auto-consolidated knowledge from memories",
             "- Check `is_stale` field - if stale, ALSO use recall() to verify",
             "- Good for understanding patterns and summaries"
           ]},
        {"RAW FACTS (recall) - Ground Truth",
         [
           "- Individual memories (world facts and experiences)",
           "- Use when higher tiers are missing, stale, or you need specific details",
           "- MANDATORY: if the higher tiers return 0 results, you MUST call recall() before giving up",
           "- This is the source of truth that other levels are built from"
         ]}
      ]
      |> Enum.filter(& &1)

    count = length(levels)
    suffixes = level_suffixes(count)

    header =
      case count do
        1 -> "You have access to ONE level of knowledge:"
        2 -> "You have access to TWO levels of knowledge. Use them in this order:"
        _ -> "You have access to THREE levels of knowledge. Use them in this order:"
      end

    body =
      levels
      |> Enum.with_index()
      |> Enum.flat_map(fn {{title, lines}, idx} ->
        ["### #{idx + 1}. #{title}#{Enum.at(suffixes, idx)}"] ++ lines ++ [""]
      end)

    ["## HIERARCHICAL RETRIEVAL STRATEGY", "", header, ""] ++ body
  end

  defp level_suffixes(1), do: [""]
  defp level_suffixes(2), do: [" - Try First", ""]
  defp level_suffixes(_), do: [" - Try First", " - Second Priority", ""]

  defp query_strategy do
    [
      "## Query Strategy",
      "recall() uses semantic search. NEVER just echo the user's question - decompose it into targeted searches:",
      "",
      "Think: What ENTITIES and CONCEPTS does this question involve? Search for each separately.",
      ""
    ]
  end

  defp budget_guidance("low"),
    do: [
      "## RESEARCH DEPTH: SHALLOW (Quick Response)",
      "- Prioritize speed over completeness; if a higher tier gives a reasonable answer, stop there.",
      ""
    ]

  defp budget_guidance("high"),
    do: [
      "## RESEARCH DEPTH: DEEP (Thorough Exploration)",
      "- Explore comprehensively before answering; use multiple query variations and expand() for full context.",
      ""
    ]

  defp budget_guidance("mid"),
    do: [
      "## RESEARCH DEPTH: MODERATE (Balanced)",
      "- Balance thoroughness with efficiency; verify stale data if central to the answer.",
      ""
    ]

  defp budget_guidance(_), do: []

  defp workflow(has_mm, include_obs) do
    steps =
      [
        has_mm && "First, try search_mental_models() — check if a curated summary exists.",
        include_obs &&
          if(has_mm,
            do:
              "If no mental model or it's stale, try search_observations() for consolidated knowledge.",
            else: "First, try search_observations() — check for consolidated knowledge."
          ),
        "If higher tiers are missing/stale or you need specifics, use recall() for raw facts.",
        "Use expand() when a recalled fact is truncated or needs its surrounding document.",
        "Once you have gathered supporting evidence, answer in plain text (no tool call). Do NOT answer before retrieving evidence."
      ]
      |> Enum.filter(& &1)
      |> Enum.with_index(1)
      |> Enum.map(fn {step, idx} -> "#{idx}. #{step}" end)

    ["## Workflow" | steps]
  end

  # --- directives -------------------------------------------------------------

  defp directives_section([]), do: []

  defp directives_section(directives) do
    rules =
      directives
      |> Enum.map(&directive_text/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&("- " <> &1))

    case rules do
      [] -> []
      _ -> ["## DIRECTIVES (hard rules — highest priority)"] ++ rules ++ [""]
    end
  end

  defp directive_text(%{} = directive) do
    directive["text"] || directive[:text] || directive["content"] || directive[:content] ||
      directive["name"] || directive[:name]
  end

  defp directive_text(_), do: nil

  defp profile_field(profile, key) when is_map(profile) do
    Map.get(profile, key) || Map.get(profile, String.to_atom(key))
  end

  defp profile_field(_profile, _key), do: nil

  # Render the bank's disposition traits into behavioural prose (skeptical vs
  # trusting, literal vs interpretive, detached vs empathetic). Empty when the bank sets
  # no disposition, so the prompt is unchanged for banks that don't use it.
  defp disposition_section(bank_profile) do
    case Foresight.Reflect.Disposition.describe(profile_field(bank_profile, "disposition")) do
      "" -> []
      desc -> [desc, ""]
    end
  end
end
