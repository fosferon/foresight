defmodule Foresight.Repo.Migrations.AddSupersessionEdges do
  @moduledoc """
  First-class supersession/contradiction edges.

  Extends `memory_links.link_type` with `supersedes` / `contradicts` / `refines`, and adds
  `memory_units.superseded_at` so consolidation can mark a superseded observation instead
  of destructively deleting it. The row and a `supersedes` edge are retained for
  history/audit while the superseded observation is excluded from active recall — the
  non-destructive counterpart to Hindsight's hard-delete.
  """
  use Ecto.Migration

  def up do
    drop(constraint(:memory_links, :memory_links_link_type_check))

    create(
      constraint(:memory_links, :memory_links_link_type_check,
        check:
          "link_type IN ('semantic','temporal','caused_by','entity','supersedes','contradicts','refines')"
      )
    )

    alter table(:memory_units) do
      add(:superseded_at, :utc_datetime_usec)
    end

    # Recall demotion filters on superseded_at per bank; partial index keeps it cheap since
    # superseded rows are the minority.
    create(
      index(:memory_units, [:bank_id, :superseded_at],
        where: "superseded_at IS NOT NULL",
        name: :memory_units_superseded_idx
      )
    )
  end

  def down do
    drop(index(:memory_units, [:bank_id, :superseded_at], name: :memory_units_superseded_idx))

    alter table(:memory_units) do
      remove(:superseded_at)
    end

    drop(constraint(:memory_links, :memory_links_link_type_check))

    create(
      constraint(:memory_links, :memory_links_link_type_check,
        check: "link_type IN ('semantic','temporal','caused_by','entity')"
      )
    )
  end
end
