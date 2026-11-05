defmodule Foresight.Storage.LinkConstruction do
  @moduledoc """
  Retain-time construction of the `memory_links` graph.

  Builds directed unit->unit edges so the recall graph and temporal arms have
  real, precomputed structure to expand over — restoring genuine multi-way RRF
  fusion instead of recomputing signals per-candidate at query time.

  Two link types are built here (mirrors Python Hindsight `engine/retain/link_utils.py`):

    * `semantic` — pgvector ANN. Each new unit is linked to its top-K most similar
      existing units in the same bank and `fact_type` whose cosine similarity is
      at least `@semantic_threshold`; weight = cosine similarity. Because the new
      batch is already committed when this runs, the ANN naturally covers both
      new-vs-existing and new-vs-new (sibling) neighbours.
    * `temporal` — each new unit is linked to units whose event time falls within
      `@temporal_window_hours`; weight = `max(floor, 1 - Δhours/window)`, capped at
      `@max_temporal_links_per_unit` strongest per unit.

  Not yet built:
    * `caused_by` links via LlmCore.
    * `entity`-typed unit-grain links.

  Runs POST-COMMIT (its own reads/writes, outside the retain transaction) so an
  ANN error can never poison or roll back the retain, and index probes never hold
  write locks. Best-effort: on any failure it logs and yields 0 links.
  """

  import Ecto.Query
  import Pgvector.Ecto.Query

  require Logger

  alias Foresight.Schemas.MemoryLink
  alias Foresight.Schemas.MemoryUnit

  @semantic_top_k 50
  @semantic_threshold 0.7
  # cosine distance = 1 - similarity, so similarity >= 0.7  <=>  distance <= 0.3
  @semantic_max_distance 1.0 - @semantic_threshold

  @temporal_window_hours 24
  @temporal_window_seconds @temporal_window_hours * 3600
  @temporal_candidate_limit 60
  @temporal_weight_floor 0.3
  @max_temporal_links_per_unit 20

  @doc """
  Build semantic + temporal links for a batch of just-inserted memory units.

  Returns `{:ok, links_created}`. Never raises — an internal error is logged and
  reported as `{:ok, 0}` so retain is unaffected.
  """
  @spec build_links(Ecto.Repo.t(), String.t(), [MemoryUnit.t()], keyword()) ::
          {:ok, non_neg_integer()}
  def build_links(repo, bank_id, inserted_units, repo_opts) do
    links =
      semantic_links(repo, bank_id, inserted_units, repo_opts) ++
        temporal_links(repo, bank_id, inserted_units, repo_opts)

    insert_links(repo, links, repo_opts)
  rescue
    error ->
      Logger.warning(
        "[link_construction] skipped for bank=#{bank_id}: #{Exception.message(error)}"
      )

      {:ok, 0}
  end

  # --- semantic ---

  defp semantic_links(repo, bank_id, units, repo_opts) do
    units
    |> Enum.flat_map(fn unit ->
      case unit_vector(unit) do
        nil ->
          []

        {vector_field, vec} ->
          repo.all(semantic_query(bank_id, unit, vector_field, vec), repo_opts)
          |> Enum.map(fn %{id: to_id, distance: distance} ->
            similarity = clamp01(1.0 - distance)
            link_row(bank_id, unit.id, to_id, "semantic", similarity)
          end)
      end
    end)
  end

  defp semantic_query(bank_id, unit, vector_field, vec) do
    from(mu in MemoryUnit,
      where:
        mu.bank_id == ^bank_id and mu.fact_type == ^unit.fact_type and mu.id != ^unit.id and
          not is_nil(field(mu, ^vector_field)),
      where: cosine_distance(field(mu, ^vector_field), ^vec) <= ^@semantic_max_distance,
      order_by: cosine_distance(field(mu, ^vector_field), ^vec),
      limit: ^@semantic_top_k,
      select: %{id: mu.id, distance: cosine_distance(field(mu, ^vector_field), ^vec)}
    )
  end

  # The unit's own vector column, whatever width its bank is pinned to. This used to
  # know only 384 and 1024, so banks on 1536 never got semantic links (their graph
  # arm stayed dark) and 3072 would have been the same.
  defp unit_vector(%{embedded_dim: dim} = unit) when is_integer(dim) do
    case Foresight.Embeddings.Profile.vector(unit) do
      nil -> nil
      vec -> {Foresight.Embeddings.Profile.vector_field(dim), vec}
    end
  rescue
    KeyError -> nil
  end

  defp unit_vector(_unit), do: nil

  # --- temporal ---

  defp temporal_links(repo, bank_id, units, repo_opts) do
    units
    |> Enum.flat_map(fn unit ->
      case anchor(unit) do
        nil ->
          []

        anchor_ts ->
          lower = DateTime.add(anchor_ts, -@temporal_window_seconds, :second)
          upper = DateTime.add(anchor_ts, @temporal_window_seconds, :second)

          repo.all(temporal_query(bank_id, unit, lower, upper), repo_opts)
          |> Enum.map(fn %{id: to_id, anchor: candidate_ts} ->
            delta_hours = abs(DateTime.diff(anchor_ts, candidate_ts, :second)) / 3600.0
            weight = max(@temporal_weight_floor, 1.0 - delta_hours / @temporal_window_hours)
            {to_id, weight}
          end)
          |> Enum.sort_by(fn {_id, weight} -> weight end, :desc)
          |> Enum.take(@max_temporal_links_per_unit)
          |> Enum.map(fn {to_id, weight} ->
            link_row(bank_id, unit.id, to_id, "temporal", weight)
          end)
      end
    end)
  end

  defp temporal_query(bank_id, unit, lower, upper) do
    from(mu in MemoryUnit,
      where: mu.bank_id == ^bank_id and mu.fact_type == ^unit.fact_type and mu.id != ^unit.id,
      where:
        fragment(
          "COALESCE(?, ?, ?, ?) BETWEEN ? AND ?",
          mu.occurred_end,
          mu.occurred_start,
          mu.occurred_at,
          mu.mentioned_at,
          ^lower,
          ^upper
        ),
      limit: ^@temporal_candidate_limit,
      select: %{
        id: mu.id,
        # type/2 loads the COALESCE result as a DateTime; a bare fragment would
        # return a NaiveDateTime (Ecto stores utc_datetime in a tz-less column),
        # which DateTime.diff/3 rejects.
        anchor:
          type(
            fragment(
              "COALESCE(?, ?, ?, ?)",
              mu.occurred_end,
              mu.occurred_start,
              mu.occurred_at,
              mu.mentioned_at
            ),
            :utc_datetime_usec
          )
      }
    )
  end

  defp anchor(unit) do
    unit.occurred_end || unit.occurred_start || unit.occurred_at || unit.mentioned_at
  end

  # --- insert ---

  defp insert_links(_repo, [], _repo_opts), do: {:ok, 0}

  defp insert_links(repo, links, repo_opts) do
    deduped =
      links
      |> Enum.group_by(fn link -> {link.from_unit_id, link.to_unit_id, link.link_type} end)
      |> Enum.map(fn {_key, group} -> Enum.max_by(group, & &1.weight) end)

    {count, _} =
      repo.insert_all(
        MemoryLink,
        deduped,
        Keyword.merge(repo_opts,
          on_conflict: :nothing,
          conflict_target: [:from_unit_id, :to_unit_id, :link_type]
        )
      )

    {:ok, count}
  end

  defp link_row(bank_id, from_id, to_id, link_type, weight) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      bank_id: bank_id,
      from_unit_id: from_id,
      to_unit_id: to_id,
      link_type: link_type,
      weight: weight * 1.0,
      inserted_at: now,
      updated_at: now
    }
  end

  defp clamp01(value) when value < 0.0, do: 0.0
  defp clamp01(value) when value > 1.0, do: 1.0
  defp clamp01(value), do: value
end
