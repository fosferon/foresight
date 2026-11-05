defmodule Foresight.Entities.ResolutionTest do
  @moduledoc """
  Unit tests for the entity-resolution scorer. Pure logic,
  default lane. Asserts merge/create OUTCOMES plus the three-signal weighting and
  threshold semantics. Name-similarity numbers are pinned to Hindsight's metric —
  `difflib.SequenceMatcher.ratio` (`entity_resolver.py:664`) — via
  `Foresight.Text.SequenceMatcher`, so the boundary cases below encode Hindsight's
  actual merge/create decisions, not a lookalike metric's.
  """
  use ExUnit.Case, async: true

  alias Foresight.Entities.Resolution

  @day1 ~U[2024-03-01 00:00:00Z]

  defp cand(id, name, opts \\ []) do
    base = %{
      id: id,
      name: name,
      last_seen: Keyword.get(opts, :last_seen),
      cooccurring: Keyword.get(opts, :cooccurring, MapSet.new())
    }

    # Add :semantic_similarity only when the test supplies it, so the "absent
    # semantic" case genuinely omits the key.
    case Keyword.fetch(opts, :semantic) do
      {:ok, sim} -> Map.put(base, :semantic_similarity, sim)
      :error -> base
    end
  end

  describe "name-similarity alone cannot merge (needs corroboration)" do
    test "identical name with no temporal/cooccurrence signal → create" do
      # SequenceMatcher('google','google')=1.0 × 0.5 = 0.5, not > 0.6
      assert Resolution.resolve("Google", [cand("e1", "Google")]) == :create
    end

    test "identical name + same-day recency → merge" do
      # 1.0×0.5 + 1.0×0.2 = 0.7 > 0.6
      assert Resolution.resolve("Google", [cand("e1", "Google", last_seen: @day1)],
               event_date: @day1
             ) == {:merge, "e1"}
    end
  end

  describe "fuzzy name matching pinned to Hindsight's SequenceMatcher boundary" do
    test "'google inc' vs 'Google' + same-day recency stays BELOW threshold → create" do
      # This is the load-bearing case. difflib ratio('google inc','google')
      # = 0.75, so name contributes 0.375; + same-day temporal 0.2 = 0.575, which is
      # NOT > 0.6. Hindsight would create a distinct entity here — Jaro (≈0.867 →
      # 0.633) would have wrongly merged. See Foresight.Text.SequenceMatcher.
      assert Resolution.resolve("google inc", [cand("e1", "Google", last_seen: @day1)],
               event_date: @day1
             ) == :create
    end

    test "'google inc' clears threshold once co-occurrence corroborates" do
      # 0.375 name + same-day 0.2 + (1/1 nearby overlap)×0.3 = 0.875 > 0.6 → merge.
      c = cand("e1", "Google", last_seen: @day1, cooccurring: MapSet.new(["android"]))

      assert Resolution.resolve("google inc", [c], event_date: @day1, nearby: ["Android"]) ==
               {:merge, "e1"}
    end

    test "a genuinely close name ('goggle' vs 'google') merges with recency" do
      # ratio('goggle','google')=0.8333 → 0.4167 name + same-day 0.2 = 0.6167 > 0.6.
      assert Resolution.resolve("goggle", [cand("e1", "Google", last_seen: @day1)],
               event_date: @day1
             ) == {:merge, "e1"}
    end

    test "unrelated names do not merge even with recency" do
      # ratio('umbrella','google')=0.1428 → 0.071 name + 0.2 = 0.271, well under 0.6.
      assert Resolution.resolve("Umbrella", [cand("e1", "Google", last_seen: @day1)],
               event_date: @day1
             ) == :create
    end
  end

  describe "co-occurrence signal" do
    test "shared nearby entity corroborates an identical name → merge" do
      c = cand("e1", "Paris", cooccurring: MapSet.new(["france", "eiffel tower"]))
      # 1.0×0.5 + (1/1)×0.3 = 0.8 > 0.6
      assert Resolution.resolve("Paris", [c], nearby: ["France"]) == {:merge, "e1"}
    end

    test "cooccurring accepts a plain list and lowercases it" do
      c = cand("e1", "Paris", cooccurring: ["France", "Eiffel Tower"])
      assert Resolution.resolve("Paris", [c], nearby: ["france"]) == {:merge, "e1"}
    end

    test "nearby excludes the mention's own name (no self co-occurrence)" do
      c = cand("e1", "Paris", cooccurring: MapSet.new(["paris"]))
      # self filtered → nearby empty → cooccur 0 → 0.5 only → create
      assert Resolution.resolve("Paris", [c], nearby: ["Paris"]) == :create
    end

    test "partial overlap scales the co-occurrence contribution" do
      c = cand("e1", "Paris", cooccurring: MapSet.new(["france"]))
      # overlap 1 of 2 nearby = 0.5 × 0.3 = 0.15; +0.5 name = 0.65 > 0.6 → merge
      assert Resolution.resolve("Paris", [c], nearby: ["France", "Berlin"]) == {:merge, "e1"}
    end
  end

  describe "temporal window" do
    test "beyond the 7-day window contributes nothing → create" do
      eight_days_later = DateTime.add(@day1, 8 * 86_400, :second)

      assert Resolution.resolve("Google", [cand("e1", "Google", last_seen: @day1)],
               event_date: eight_days_later
             ) == :create
    end

    test "temporal_proximity decays linearly and is symmetric in time direction" do
      # via score/4: identical name (0.5) leaves temporal to carry the rest
      empty = MapSet.new()
      same = Resolution.score("Google", cand("e1", "Google", last_seen: @day1), empty, @day1)
      assert_in_delta same, 0.7, 1.0e-6

      mid = DateTime.add(@day1, div(7 * 86_400, 2), :second)
      half = Resolution.score("Google", cand("e1", "Google", last_seen: @day1), empty, mid)
      # temporal = 1 - 3.5/7 = 0.5 → 0.5×0.2 = 0.1 → 0.6
      assert_in_delta half, 0.6, 1.0e-6

      before = DateTime.add(@day1, -3 * 86_400, :second)

      after_score =
        Resolution.score("Google", cand("e1", "Google", last_seen: @day1), empty, before)

      # |Δ| symmetric: 3 days either side gives the same temporal contribution
      assert_in_delta after_score, 0.5 + (1.0 - 3.0 / 7.0) * 0.2, 1.0e-6
    end
  end

  describe "candidate selection" do
    test "no candidates → create" do
      assert Resolution.resolve("Google", []) == :create
    end

    test "picks the highest-scoring candidate" do
      strong = cand("e1", "Google", last_seen: @day1)
      weak = cand("e2", "Goggle")

      assert Resolution.resolve("Google", [weak, strong], event_date: @day1) == {:merge, "e1"}
    end
  end

  describe "semantic name signal (extension): name = max(lexical, semantic)" do
    # A candidate may carry :semantic_similarity — the cosine between the mention's
    # name embedding and the candidate's. The name component takes the STRONGER of
    # lexical (SequenceMatcher) and semantic, so a lexically-distant but semantically-
    # equivalent variant ("NYC" ↔ "New York City") gets name credit Hindsight cannot.
    test "semantic-only match still needs corroboration (name alone caps at 0.5)" do
      # lexical('nyc','new york city') is low; semantic 0.9 → name 0.45, not > 0.6.
      c = cand("e1", "New York City", semantic: 0.9)
      assert Resolution.resolve("NYC", [c]) == :create
    end

    test "semantic variant merges once recency corroborates" do
      # max(low, 0.9)=0.9 → 0.45 name + same-day 0.2 = 0.65 > 0.6 → merge.
      c = cand("e1", "New York City", last_seen: @day1, semantic: 0.9)
      assert Resolution.resolve("NYC", [c], event_date: @day1) == {:merge, "e1"}
    end

    test "weak semantic similarity does not manufacture a merge" do
      # max(low_lexical, 0.3)=0.3 → 0.15 name + same-day 0.2 = 0.35, under 0.6.
      c = cand("e1", "New York City", last_seen: @day1, semantic: 0.3)
      assert Resolution.resolve("NYC", [c], event_date: @day1) == :create
    end

    test "absent semantic signal falls back to lexical (parity preserved)" do
      # No :semantic key → identical to the lexical-only score.
      c = cand("e1", "Google", last_seen: @day1)
      assert Resolution.resolve("Google", [c], event_date: @day1) == {:merge, "e1"}
    end

    test "lexical wins when it is the stronger of the two" do
      # identical name (lexical 1.0) beats a mediocre semantic 0.4 via max.
      c = cand("e1", "Google", last_seen: @day1, semantic: 0.4)
      assert_in_delta Resolution.score("Google", c, MapSet.new(), @day1), 0.7, 1.0e-9
    end
  end

  describe "label-entity exact-match guard (F4)" do
    # Faithful to entity_resolver.py:_resolve_from_candidates label branch
    # (is_label_entity → exact case-insensitive match only, never fuzzy), so distinct
    # label VALUES that look alike (use:use-001 vs use:use-002) are never merged.
    test "a label entity merges only on an EXACT (case-insensitive) name match" do
      exact = cand("e1", "USE:USE-001", last_seen: @day1)

      assert Resolution.resolve("use:use-001", [exact],
               labels: ["use:use-001"],
               event_date: @day1
             ) == {:merge, "e1"}
    end

    test "a label entity does NOT fuzzy-merge into a similar label value" do
      # Without the guard, same-day recency + high name similarity would merge these.
      similar = cand("e1", "use:use-002", last_seen: @day1)

      assert Resolution.resolve("use:use-001", [similar],
               labels: ["use:use-001", "use:use-002"],
               event_date: @day1
             ) == :create
    end

    test "label detection also works by key prefix" do
      similar = cand("e1", "use:use-002", last_seen: @day1)

      assert Resolution.resolve("use:use-001", [similar],
               label_prefixes: ["use"],
               event_date: @day1
             ) == :create
    end

    test "non-label mentions are unaffected (fuzzy path still runs)" do
      c = cand("e1", "Google", last_seen: @day1)
      # "use:" prefix configured, but this mention is not a label → normal scoring.
      assert Resolution.resolve("Google", [c], label_prefixes: ["use"], event_date: @day1) ==
               {:merge, "e1"}
    end
  end

  describe "candidate_match?/2 (Hindsight full-strategy substring filter)" do
    # Faithful to entity_resolver.py:_resolve_entities_batch_full — a bank entity is
    # only a resolution candidate if its lowercased name exactly equals, contains, or
    # is contained by the mention. Scoring never sees non-substring entities, so a
    # near-miss like "goggle"/"google" is not even a candidate (→ create), while
    # "google inc"/"Google" is (→ scored, then the 0.6 threshold decides).
    test "exact match (case-insensitive)" do
      assert Resolution.candidate_match?("Google", "google")
    end

    test "mention is a substring of the canonical name" do
      assert Resolution.candidate_match?("google", "Google Inc")
    end

    test "canonical name is a substring of the mention" do
      assert Resolution.candidate_match?("google inc", "Google")
    end

    test "no substring relation → not a candidate" do
      refute Resolution.candidate_match?("goggle", "google")
      refute Resolution.candidate_match?("Umbrella", "Google")
    end

    test "empty strings are not candidates (guarded)" do
      refute Resolution.candidate_match?("", "google")
      refute Resolution.candidate_match?("google", "")
    end
  end

  describe "threshold override" do
    test "a lower threshold admits a name-only match" do
      assert Resolution.resolve("Google", [cand("e1", "Google")], threshold: 0.4) ==
               {:merge, "e1"}
    end
  end
end
