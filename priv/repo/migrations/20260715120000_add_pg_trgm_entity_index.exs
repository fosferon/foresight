defmodule Foresight.Repo.Migrations.AddPgTrgmEntityIndex do
  use Ecto.Migration

  # pg_trgm powers Hindsight's intended fuzzy entity-resolution candidate lookup
  # (entity_resolver.py trigram strategy): typo/variant names that are NOT substrings
  # of each other — "goggle"~"google", "Microsft"~"Microsoft" — are surfaced by
  # trigram similarity, then scored by the SequenceMatcher name metric. Without it the
  # resolver can only ever match substrings, so the precision scorer never sees the
  # variants it exists to judge.
  #
  # Best-effort by design: if the login lacks CREATE EXTENSION rights the resolver
  # auto-detects the extension's absence at runtime and falls back to the substring
  # "full" strategy (matching entity_resolver.py:285-296). The GIN index only makes
  # the similarity() lookup index-backed instead of a sequential scan.
  #
  # The extension is database-global (idempotent CREATE), but the index is per-schema:
  # raw `execute` does NOT inherit the migration prefix, so the table is schema-
  # qualified with prefix() so the provisioner lands the index in each tenant schema's
  # `entities` table (mirroring the pin_bank_embedding_profile migration).
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    schema = ~s("#{prefix() || "public"}")

    execute("""
    CREATE INDEX IF NOT EXISTS entities_canonical_name_trgm_idx
    ON #{schema}.entities USING gin (lower(canonical_name) gin_trgm_ops)
    """)
  end

  def down do
    schema = ~s("#{prefix() || "public"}")
    execute("DROP INDEX IF EXISTS #{schema}.entities_canonical_name_trgm_idx")
    # Leave the extension installed — other objects may come to depend on it.
  end
end
