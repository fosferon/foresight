defmodule Foresight.Entities.Resolution do
  @moduledoc """
  Entity resolution scoring — decide whether an incoming
  entity mention resolves to an existing bank entity or creates a new one.

  Faithful port of Hindsight's `engine/entity_resolver.py` `_resolve_from_candidates`
  three-signal scorer. For each candidate the score in `[0.0, 1.0]` is:

      name_similarity  × 0.5   (how alike the surface strings are)
    + cooccurrence     × 0.3   (share of the mention's nearby entities that this
                                candidate has historically co-occurred with)
    + temporal         × 0.2   (recency: 1.0 when last seen today, linearly to 0
                                at a 7-day window, 0 beyond)

  The best-scoring candidate is merged into iff its score is strictly greater than
  the threshold (default 0.6, matching Hindsight); otherwise a new entity is created.
  Because name-similarity alone caps at 0.5, a merge always requires at least one
  corroborating signal (co-occurrence or recency) — the same property that keeps
  Hindsight from collapsing two unrelated entities that merely share a substring.

  Name-similarity is computed by `Foresight.Text.SequenceMatcher.ratio/2`, a
  faithful port of Hindsight's `difflib.SequenceMatcher(None, a, b).ratio()`
  (`entity_resolver.py:664`) on lowercased inputs — so the 0.6 threshold is a
  byte-faithful constant, not a calibratable knob. Concretely, "google inc" vs
  "Google" scores 0.75 → 0.375, which even with same-day recency (0.575) stays
  below threshold and does NOT merge, exactly as Hindsight decides. An optional
  semantic (embedding) term covers cases lexical similarity alone cannot disambiguate
  (e.g. "NYC" ↔ "New York City").

  Pure and side-effect-free: candidate loading, co-occurrence assembly, and the
  upsert live in the storage layer, which calls `resolve/3` per mention.
  """

  @name_weight 0.5
  @cooccurrence_weight 0.3
  @temporal_weight 0.2
  @default_threshold 0.6
  @temporal_window_days 7.0

  @typedoc """
  A resolution candidate: an existing bank entity with the signals the scorer needs.

    * `:id` — opaque identifier returned on a merge
    * `:name` — the candidate's canonical name
    * `:last_seen` — when the entity was last mentioned (`nil` → no temporal signal)
    * `:cooccurring` — lowercased names this entity has historically co-occurred with
    * `:semantic_similarity` — optional extension beyond Hindsight: cosine between the mention's name embedding
      and this candidate's (`0.0`/absent → lexical-only, i.e. parity)
  """
  @type candidate :: %{
          :id => term(),
          :name => String.t(),
          optional(:last_seen) => DateTime.t() | nil,
          optional(:cooccurring) => MapSet.t(String.t()) | [String.t()],
          optional(:semantic_similarity) => number() | nil
        }

  @doc """
  Resolve `name` against `candidates`, returning `{:merge, id}` or `:create`.

  Opts:
    * `:nearby` — other entity names mentioned alongside `name` (for co-occurrence);
      the mention's own name is filtered out. Default `[]`.
    * `:event_date` — when this mention occurred, for the temporal signal. Default `nil`.
    * `:threshold` — minimum winning score to merge (strict `>`). Default `0.6`.
    * `:labels` — label taxonomy values (enum groups); `:label_prefixes` — label key
      prefixes (text groups). When `name` is a label entity, the fuzzy scorer is
      skipped and only an EXACT case-insensitive name match merges — faithful to
      Hindsight's label guard (`entity_resolver.py`, is_label_entity), so distinct
      label values that look alike are never merged. (Map-group label recursion is not
      ported — Foresight has no map-label config.)
  """
  @spec resolve(String.t(), [candidate()], keyword()) :: {:merge, term()} | :create
  def resolve(name, candidates, opts \\ [])
      when is_binary(name) and is_list(candidates) do
    if label_entity?(name, opts) do
      resolve_label(name, candidates)
    else
      resolve_fuzzy(name, candidates, opts)
    end
  end

  defp resolve_fuzzy(name, candidates, opts) do
    nearby = build_nearby(name, Keyword.get(opts, :nearby, []))
    event_date = Keyword.get(opts, :event_date)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    {best_id, best_score} =
      Enum.reduce(candidates, {nil, 0.0}, fn candidate, {_id, best} = acc ->
        s = score(name, candidate, nearby, event_date)
        if s > best, do: {candidate.id, s}, else: acc
      end)

    if not is_nil(best_id) and best_score > threshold do
      {:merge, best_id}
    else
      :create
    end
  end

  # Label entities resolve by exact case-insensitive name ONLY (no fuzzy scoring).
  defp resolve_label(name, candidates) do
    n = String.downcase(name)

    case Enum.find(candidates, fn c -> String.downcase(c.name) == n end) do
      nil -> :create
      candidate -> {:merge, candidate.id}
    end
  end

  defp label_entity?(name, opts) do
    n = String.downcase(name)
    labels = opts |> Keyword.get(:labels, []) |> Enum.map(&String.downcase/1) |> MapSet.new()
    prefixes = Keyword.get(opts, :label_prefixes, [])

    MapSet.member?(labels, n) or
      Enum.any?(prefixes, fn p -> String.starts_with?(n, String.downcase(p) <> ":") end)
  end

  @doc """
  Whether an existing entity named `canonical` is even eligible to be scored as a
  candidate for the mention `name`.

  Faithful port of Hindsight's full-strategy filter
  (`entity_resolver.py:_resolve_entities_batch_full`): case-insensitive, a match iff
  the names are equal, or one is a substring of the other. The 3-signal scorer only
  ever sees entities that pass this filter, so a near-miss with no substring relation
  (e.g. "goggle"/"google") is never a merge candidate. Empty names are guarded out —
  they are dropped upstream (`fact_entities`), and Python's `"" in s == true` would
  otherwise make an empty mention match every entity.
  """
  @spec candidate_match?(String.t(), String.t()) :: boolean()
  def candidate_match?(name, canonical) when is_binary(name) and is_binary(canonical) do
    n = String.downcase(name)
    c = String.downcase(canonical)

    n != "" and c != "" and
      (n == c or String.contains?(c, n) or String.contains?(n, c))
  end

  @doc """
  Score one `candidate` for the mention `name` (with its `nearby` set and
  `event_date`). Exposed for testing and diagnostics.
  """
  @spec score(String.t(), candidate(), MapSet.t(String.t()), DateTime.t() | nil) :: float()
  def score(name, candidate, nearby, event_date) do
    name_component(name, candidate) * @name_weight +
      cooccurrence_overlap(nearby, candidate) * @cooccurrence_weight +
      temporal_proximity(event_date, Map.get(candidate, :last_seen)) * @temporal_weight
  end

  # --- signals ---

  # Name signal (semantic extension): the STRONGER of lexical (SequenceMatcher, Hindsight's
  # metric) and semantic (embedding cosine, when the storage layer supplies it).
  # Falls back to pure lexical when :semantic_similarity is absent, so parity holds.
  # Still capped at 1.0, so name alone can never exceed 0.5 — a semantic match, like a
  # lexical one, always needs co-occurrence or recency corroboration to merge.
  defp name_component(name, candidate) do
    lexical = name_similarity(name, candidate.name)
    semantic = candidate |> Map.get(:semantic_similarity, 0.0) |> clamp_unit()
    max(lexical, semantic)
  end

  defp clamp_unit(x) when is_number(x), do: x |> max(0.0) |> min(1.0)
  defp clamp_unit(_), do: 0.0

  defp name_similarity(a, b) do
    Foresight.Text.SequenceMatcher.ratio(String.downcase(a), String.downcase(b))
  end

  defp cooccurrence_overlap(nearby, candidate) do
    nearby_count = MapSet.size(nearby)

    if nearby_count == 0 do
      0.0
    else
      cooccurring = candidate |> Map.get(:cooccurring, MapSet.new()) |> to_mapset()
      overlap = nearby |> MapSet.intersection(cooccurring) |> MapSet.size()
      overlap / nearby_count
    end
  end

  defp temporal_proximity(nil, _last_seen), do: 0.0
  defp temporal_proximity(_event_date, nil), do: 0.0

  defp temporal_proximity(event_date, last_seen) do
    days = abs(DateTime.diff(event_date, last_seen, :second)) / 86_400.0

    if days < @temporal_window_days do
      max(0.0, 1.0 - days / @temporal_window_days)
    else
      0.0
    end
  end

  # --- helpers ---

  # Nearby entity names, lowercased and deduped, with the mention's own name
  # removed (an entity does not co-occur with itself).
  defp build_nearby(name, nearby_names) do
    self_lower = String.downcase(name)

    nearby_names
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == self_lower))
    |> MapSet.new()
  end

  defp to_mapset(%MapSet{} = set), do: set

  defp to_mapset(list) when is_list(list),
    do: list |> Enum.map(&String.downcase/1) |> MapSet.new()

  defp to_mapset(_other), do: MapSet.new()
end
