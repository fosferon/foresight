defmodule Foresight.Evals.RecallQuality do
  @moduledoc """
  QUARANTINED. This is the legacy phrase-matching grader. It scores answers by
  checking for the presence of specific corpus phrases, which is exactly the signal the
  production ranking code was once gamed to satisfy — so its numbers measure phrase echo,
  not retrieval quality, and MUST NOT be cited as a quality metric.

  It is retained only as a fixed regression fixture (its scenarios and text matchers are
  frozen and unit-tested for their own stable behaviour). Honest recall quality is measured
  by `Foresight.Evals.RankingMetrics` over the held-out corpus
  (`Foresight.TestSupport.Evals.HoldoutCorpus`), which scores id-based ranking and cannot
  be satisfied by emitting a phrase. Do not add scenarios here; extend the held-out corpus.
  """

  def scenarios do
    [
      %{
        id: "oxford-delay",
        class: "explicit",
        query: "After Oxford, what did Alice and I decide about the Foresight cutover?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven."
      },
      %{
        id: "lmstudio-proof",
        class: "paraphrase",
        query:
          "What was the reason we decided not to launch Foresight yet after the Oxford visit?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "We decided to hold off on launching Foresight until LMStudio could prove the reflect lane on real diary-style memory.",
        acceptable_texts: [
          "We decided to hold off on launching Foresight until LMStudio could prove the reflect lane on real diary-style memory.",
          "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven.",
          "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven."
        ]
      },
      %{
        id: "stale-vs-corrected",
        class: "superseded",
        query:
          "What correction replaced the initial hot take that we should ship Foresight immediately after Oxford?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven."
      },
      %{
        id: "latest-over-earlier-hot-take",
        class: "temporal",
        query: "What was our latest position on the Foresight launch after the Oxford debrief?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality."
      },
      %{
        id: "not-immediate-launch",
        class: "contradiction",
        query: "Did we approve shipping Foresight immediately after Oxford?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven.",
        acceptable_texts: [
          "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven.",
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality."
        ]
      },
      %{
        id: "helios-diary-gate",
        class: "project-gate",
        query: "What condition did helios-diary care about before cutting over to Foresight?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "We wanted helios-diary to cut over only after the Foresight memory path felt industrial-strength under real recall and reflect load."
      },
      %{
        id: "python-authority-remains",
        class: "fallback",
        query: "What were we keeping in place while Foresight was still being proven?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality.",
        acceptable_texts: [
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality.",
          "We kept the Python Hindsight authority live as the fallback while the Foresight recall and reflect lane was being qualified."
        ]
      },
      %{
        id: "fallback-purpose",
        class: "causal",
        query:
          "Why did we keep the Python Hindsight authority running during the Foresight qualification period?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "We kept the Python Hindsight authority live as the fallback while the Foresight recall and reflect lane was being qualified.",
        acceptable_texts: [
          "We kept the Python Hindsight authority live as the fallback while the Foresight recall and reflect lane was being qualified.",
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality."
        ]
      },
      %{
        id: "port-instability-not-gate",
        class: "causal-negative",
        query: "Was authority port instability the real reason we delayed the Foresight cutover?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "Authority port instability came up, but it was not the governing cutover gate; the real bar was proving recall and reflect quality on diary-style memory.",
        acceptable_texts: [
          "Authority port instability came up, but it was not the governing cutover gate; the real bar was proving recall and reflect quality on diary-style memory.",
          "We decided to hold off on launching Foresight until LMStudio could prove the reflect lane on real diary-style memory."
        ]
      },
      %{
        id: "next-week-not-the-plan",
        class: "schedule-negative",
        query: "Did we simply move the Foresight launch to next week after Oxford?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "We did not set a next-week launch date; we waited for industrial-strength recall and reflect quality instead of a calendar-based cutover.",
        acceptable_texts: [
          "We did not set a next-week launch date; we waited for industrial-strength recall and reflect quality instead of a calendar-based cutover.",
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality."
        ]
      },
      %{
        id: "real-gate-over-schedule",
        class: "quality-gate",
        query:
          "What mattered more than scheduling chatter or port worries before helios-diary could cut over?",
        query_timestamp: "2026-01-05T12:00:00Z",
        expected_text:
          "The real gate was industrial-strength recall and reflect quality on diary-style memory, not schedule chatter or authority-port noise.",
        acceptable_texts: [
          "The real gate was industrial-strength recall and reflect quality on diary-style memory, not schedule chatter or authority-port noise.",
          "We wanted helios-diary to cut over only after the Foresight memory path felt industrial-strength under real recall and reflect load."
        ]
      }
    ]
  end

  def corpus do
    core_items() ++ distractor_items()
  end

  def reflect_corpus do
    core_items() ++ reflect_distractor_items()
  end

  def reflect_scenarios do
    [
      %{
        id: "reflect-not-immediate-launch",
        class: "contradiction",
        query:
          "Did we approve shipping Foresight immediately after Oxford? Answer briefly and stay grounded.",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-corrected"],
        required_terms: ["foresight", "oxford"],
        required_any_groups: [
          ["did not approve", "not approved", "delayed", "hold off"],
          ["lmstudio", "reflect"]
        ],
        forbidden_terms: ["approved an immediate launch", "ship foresight immediately"]
      },
      %{
        id: "reflect-latest-position",
        class: "temporal",
        query:
          "What was our latest position after the Oxford debrief on cutover and fallback posture?",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-latest"],
        required_terms: ["foresight", "helios-diary"],
        required_any_groups: [
          ["python hindsight", "fallback", "in place"],
          ["industrial-strength", "recall and reflect quality", "recall and reflect load"]
        ],
        forbidden_terms: ["approved an immediate launch", "launch next week"]
      },
      %{
        id: "reflect-helios-diary-gate",
        class: "project-gate",
        query: "What condition did helios-diary care about before cutting over to Foresight?",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-gate"],
        required_terms: ["helios-diary", "foresight"],
        required_any_groups: [
          ["industrial-strength", "recall and reflect"],
          ["cut over", "cutover", "cutting over"]
        ],
        forbidden_terms: ["authority port was unstable", "diary corpus was too small"]
      },
      %{
        id: "reflect-port-instability-not-gate",
        class: "causal-negative",
        query:
          "Was authority port instability the real reason we delayed Foresight cutover after Oxford?",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-not-port"],
        required_terms: ["port", "cutover"],
        required_any_groups: [
          [
            "not the governing gate",
            "not the real reason",
            "not because of port instability",
            "not authority port instability"
          ],
          ["recall and reflect quality", "lmstudio", "diary-style memory"]
        ],
        forbidden_terms: [
          "port instability was the reason",
          "we delayed because the port was unstable"
        ]
      },
      %{
        id: "reflect-next-week-not-the-plan",
        class: "schedule-negative",
        query: "Did we just move the Foresight launch to next week after Oxford?",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-no-schedule"],
        required_terms: ["foresight"],
        required_any_groups: [
          [
            "did not set a next-week launch",
            "did not move the foresight launch to next week",
            "foresight launch was not moved to next week",
            "not next week",
            "not a next week launch"
          ],
          ["quality", "recall and reflect", "industrial-strength"]
        ],
        forbidden_terms: ["moved the launch to next week", "launch next week"]
      },
      %{
        id: "reflect-fallback-purpose",
        class: "causal",
        query:
          "Why did we keep the Python Hindsight authority running during the Foresight qualification period?",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-fallback"],
        required_terms: ["python hindsight", "foresight"],
        required_any_groups: [
          ["fallback", "in place", "kept live"],
          ["qualification", "qualified", "being proven", "still being proven"]
        ],
        forbidden_terms: [
          "only about cost",
          "disabled python hindsight immediately",
          "rely on foresight alone"
        ]
      },
      %{
        id: "reflect-real-gate-over-schedule",
        class: "quality-gate",
        query:
          "What mattered more than schedule chatter or authority-port noise before helios-diary could cut over?",
        query_timestamp: "2026-01-05T12:00:00Z",
        required_memory_ids: ["mem-real-gate"],
        required_terms: ["helios-diary"],
        required_any_groups: [
          ["real gate", "governing gate", "mattered more"],
          ["industrial-strength", "recall and reflect", "diary-style memory"],
          ["schedule", "port"]
        ],
        forbidden_terms: [
          "next-week scheduling was the gate",
          "authority port instability was the gate"
        ]
      }
    ]
  end

  def acceptable_texts(%{acceptable_texts: texts}) when is_list(texts), do: texts
  def acceptable_texts(%{expected_text: text}), do: [text]

  def matches_text?(scenario, text) when is_map(scenario) and is_binary(text) do
    normalized_text = normalize_text(text)

    exact_match? =
      scenario
      |> acceptable_texts()
      |> Enum.map(&normalize_text/1)
      |> Enum.any?(&(&1 == normalized_text))

    exact_match? or pattern_match?(scenario.id, normalized_text)
  end

  def matches_reflect_text?(scenario, text) when is_map(scenario) and is_binary(text) do
    normalized_text = normalize_text(text)
    required_terms = Map.get(scenario, :required_terms, [])
    required_any_groups = Map.get(scenario, :required_any_groups, [])
    forbidden_terms = Map.get(scenario, :forbidden_terms, [])

    contains_all?(normalized_text, required_terms) and
      Enum.all?(required_any_groups, &contains_any?(normalized_text, &1)) and
      not contains_any?(normalized_text, forbidden_terms)
  end

  def required_memory_texts(%{required_memory_ids: ids}) when is_list(ids) do
    alias_map = required_memory_alias_map()
    Enum.map(ids, &Map.get(alias_map, &1, &1))
  end

  def required_memory_texts(_scenario), do: []

  defp pattern_match?("oxford-delay", text) do
    contains_all?(text, ["delay", "foresight", "lmstudio", "reflect"])
  end

  defp pattern_match?("lmstudio-proof", text) do
    contains_all?(text, ["foresight", "lmstudio", "reflect"]) and
      contains_any?(text, ["hold off", "delay", "not approved", "not launch"])
  end

  defp pattern_match?("stale-vs-corrected", text) do
    contains_all?(text, ["foresight", "lmstudio", "reflect"]) and
      contains_any?(text, ["correction", "not approved", "delay"])
  end

  defp pattern_match?("latest-over-earlier-hot-take", text) do
    contains_all?(text, ["python hindsight authority", "helios-diary", "foresight"]) and
      contains_any?(text, ["keep", "kept"]) and
      contains_any?(text, ["industrial-strength", "recall and reflect quality"])
  end

  defp pattern_match?("not-immediate-launch", text) do
    contains_all?(text, ["foresight"]) and
      contains_any?(text, ["not approved", "delay", "hold off"])
  end

  defp pattern_match?("helios-diary-gate", text) do
    contains_all?(text, ["helios-diary", "foresight"]) and
      contains_any?(text, [
        "industrial-strength",
        "recall and reflect load",
        "recall and reflect quality"
      ])
  end

  defp pattern_match?("python-authority-remains", text) do
    contains_all?(text, ["python hindsight authority", "foresight"]) and
      contains_any?(text, ["keep", "kept", "fallback", "in place"])
  end

  defp pattern_match?("fallback-purpose", text) do
    contains_all?(text, ["python hindsight authority", "foresight"]) and
      contains_any?(text, ["fallback", "qualified", "qualification", "proven"])
  end

  defp pattern_match?("port-instability-not-gate", text) do
    contains_all?(text, ["port instability"]) and
      contains_any?(text, ["not the governing gate", "not the real reason", "not because"]) and
      contains_any?(text, ["recall and reflect quality", "lmstudio", "diary style memory"])
  end

  defp pattern_match?("next-week-not-the-plan", text) do
    contains_any?(text, [
      "not next week",
      "did not set a next week launch",
      "did not set a next-week launch"
    ]) and
      contains_any?(text, ["industrial-strength", "quality", "recall and reflect"])
  end

  defp pattern_match?("real-gate-over-schedule", text) do
    contains_any?(text, ["real gate", "what mattered more", "governing gate"]) and
      contains_any?(text, ["industrial-strength", "recall and reflect", "diary style memory"]) and
      contains_any?(text, ["schedule", "port"])
  end

  defp pattern_match?(_, _text), do: false

  defp normalize_text(text) do
    text
    |> String.replace(~r/\| when:.*$/i, "")
    |> String.replace(~r/\| involving:.*$/i, "")
    |> String.replace(~r/\| to .*$/i, "")
    |> String.split(" | ")
    |> hd()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp contains_all?(text, needles), do: Enum.all?(needles, &String.contains?(text, &1))
  defp contains_any?(text, needles), do: Enum.any?(needles, &String.contains?(text, &1))

  defp core_items do
    [
      %{
        "content" =>
          "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T19:00:00Z",
        "tags" => ["person:alice", "project:foresight", "place:oxford", "topic:cutover"]
      },
      %{
        "content" =>
          "We decided to hold off on launching Foresight until LMStudio could prove the reflect lane on real diary-style memory.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T19:10:00Z",
        "tags" => ["project:foresight", "tool:lmstudio", "topic:reflect"]
      },
      %{
        "content" =>
          "Initial hot take after Oxford: ship Foresight immediately and fix reflect quality later.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T17:00:00Z",
        "tags" => ["project:foresight", "status:superseded", "place:oxford"]
      },
      %{
        "content" =>
          "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:00:00Z",
        "tags" => ["project:foresight", "tool:lmstudio", "status:corrected", "place:oxford"]
      },
      %{
        "content" =>
          "We wanted helios-diary to cut over only after the Foresight memory path felt industrial-strength under real recall and reflect load.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:15:00Z",
        "tags" => ["project:helios-diary", "project:foresight", "topic:quality"]
      },
      %{
        "content" =>
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:30:00Z",
        "tags" => [
          "project:hindsight",
          "project:helios-diary",
          "project:foresight",
          "status:latest"
        ]
      },
      %{
        "content" =>
          "We kept the Python Hindsight authority live as the fallback while the Foresight recall and reflect lane was being qualified.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:35:00Z",
        "tags" => ["project:hindsight", "project:foresight", "topic:fallback", "status:active"]
      },
      %{
        "content" =>
          "Authority port instability came up, but it was not the governing cutover gate; the real bar was proving recall and reflect quality on diary-style memory.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:40:00Z",
        "tags" => ["project:foresight", "topic:cutover", "topic:quality", "status:clarified"]
      },
      %{
        "content" =>
          "We did not set a next-week launch date; we waited for industrial-strength recall and reflect quality instead of a calendar-based cutover.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:45:00Z",
        "tags" => ["project:foresight", "topic:schedule", "topic:quality", "status:clarified"]
      },
      %{
        "content" =>
          "The real gate was industrial-strength recall and reflect quality on diary-style memory, not schedule chatter or authority-port noise.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T20:50:00Z",
        "tags" => [
          "project:foresight",
          "project:helios-diary",
          "topic:quality",
          "status:clarified"
        ]
      }
    ]
  end

  defp required_memory_alias_map do
    %{
      "mem-corrected" =>
        "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven.",
      "mem-latest" =>
        "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality.",
      "mem-gate" =>
        "We wanted helios-diary to cut over only after the Foresight memory path felt industrial-strength under real recall and reflect load.",
      "mem-not-port" =>
        "Authority port instability came up, but it was not the governing cutover gate; the real bar was proving recall and reflect quality on diary-style memory.",
      "mem-no-schedule" =>
        "We did not set a next-week launch date; we waited for industrial-strength recall and reflect quality instead of a calendar-based cutover.",
      "mem-fallback" =>
        "We kept the Python Hindsight authority live as the fallback while the Foresight recall and reflect lane was being qualified.",
      "mem-real-gate" =>
        "The real gate was industrial-strength recall and reflect quality on diary-style memory, not schedule chatter or authority-port noise."
    }
  end

  defp distractor_items do
    people = ["Alice", "Bob", "Mira", "Nikos", "Dana"]
    places = ["Oxford", "Athens", "Milos", "London", "Cambridge"]
    projects = ["Foresight", "Argos", "helios-diary", "ops_daemon"]

    actions = [
      "approved an immediate launch",
      "moved the launch to next week",
      "switched the focus to DGX benchmarking",
      "postponed work because of budget concerns",
      "kept the Python Hindsight authority in place for another soak"
    ]

    reasons = [
      "the reranker looked noisy",
      "embedding latency spiked on cold boot",
      "the diary corpus was still too small",
      "the authority port was unstable",
      "the qualification soak had not finished"
    ]

    for index <- 1..120 do
      person = Enum.at(people, rem(index, length(people)))
      place = Enum.at(places, rem(index * 2, length(places)))
      project = Enum.at(projects, rem(index * 3, length(projects)))
      action = Enum.at(actions, rem(index * 5, length(actions)))
      reason = Enum.at(reasons, rem(index * 7, length(reasons)))

      %{
        "content" =>
          "#{person} said in #{place} that #{project} #{action} because #{reason}. [distractor #{index}]",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" =>
          "2026-01-0#{rem(index, 5) + 1}T#{String.pad_leading(Integer.to_string(rem(index * 3, 23)), 2, "0")}:00:00Z",
        "tags" => [
          "distractor",
          "project:#{String.downcase(project)}",
          "place:#{String.downcase(place)}"
        ]
      }
    end
  end

  defp reflect_distractor_items do
    [
      %{
        "content" =>
          "After Oxford we approved shipping Foresight immediately because the reranker looked noisy.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:00:00Z",
        "tags" => ["distractor", "project:foresight", "place:oxford", "status:wrong"]
      },
      %{
        "content" =>
          "After Oxford we moved the Foresight launch to next week because the authority port was unstable.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:05:00Z",
        "tags" => ["distractor", "project:foresight", "place:oxford", "status:wrong"]
      },
      %{
        "content" =>
          "Mira argued that Foresight should ship immediately because the qualification soak had not finished.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:10:00Z",
        "tags" => ["distractor", "project:foresight", "status:wrong", "person:mira"]
      },
      %{
        "content" =>
          "Nikos claimed helios-diary should cut over once the authority port stabilized, even without full recall proof.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:15:00Z",
        "tags" => ["distractor", "project:helios-diary", "project:foresight", "status:wrong"]
      },
      %{
        "content" =>
          "Temporary fallback posture was to disable Python Hindsight immediately and rely on Foresight alone.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:20:00Z",
        "tags" => ["distractor", "project:hindsight", "project:foresight", "status:wrong"]
      },
      %{
        "content" =>
          "The cutover decision depended only on next-week scheduling and not on reflect quality.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:25:00Z",
        "tags" => ["distractor", "project:foresight", "topic:cutover", "status:wrong"]
      },
      %{
        "content" =>
          "Alice wanted an immediate launch after Oxford because diary retrieval was already good enough.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:30:00Z",
        "tags" => ["distractor", "person:alice", "project:foresight", "status:wrong"]
      },
      %{
        "content" =>
          "The fallback question was only about cost, not about preserving Python Hindsight during qualification.",
        "context" => "diary",
        "type" => "world",
        "mentioned_at" => "2026-01-02T18:35:00Z",
        "tags" => ["distractor", "project:hindsight", "topic:fallback", "status:wrong"]
      }
    ]
  end
end
