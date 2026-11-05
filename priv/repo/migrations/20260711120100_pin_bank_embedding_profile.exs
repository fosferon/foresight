defmodule Foresight.Repo.Migrations.PinBankEmbeddingProfile do
  use Ecto.Migration

  # Make "a bank must not mix embedding dimensions/models" impossible by
  # construction. Each bank is pinned to one embedding profile (dim + model) on its
  # first embedded write; every subsequent embedded write is checked against the pin
  # by a BEFORE INSERT/UPDATE trigger, so a mismatched vector physically cannot be
  # persisted — independent of application code.
  #
  # Raw DDL is schema-qualified with the migration prefix (structured ops get the
  # prefix automatically, but raw `execute` does not), so the function/trigger land
  # in the correct tenant schema when the provisioner replays migrations per schema.
  # pg_dump-based cloning carries them to new tenants; the trigger body keys off
  # TG_TABLE_SCHEMA so it stays correct after schema-name substitution. The set-once
  # path uses a conditional UPDATE + re-read (no hot-path row lock), race-safe under
  # READ COMMITTED: concurrent first-writers with different profiles resolve to one
  # winner and the loser is rejected.

  def up do
    alter table(:banks) do
      add(:embedding_dim, :integer)
      add(:embedding_model, :text)
    end

    schema = ~s("#{prefix() || "public"}")

    execute("""
    CREATE OR REPLACE FUNCTION #{schema}.enforce_bank_embedding_profile() RETURNS trigger AS $enforce$
    DECLARE
      bank_dim integer;
      bank_model text;
    BEGIN
      -- Only rows that actually carry an embedding profile are constrained.
      IF NEW.embedded_dim IS NULL THEN
        RETURN NEW;
      END IF;

      EXECUTE format('SELECT embedding_dim, embedding_model FROM %I.banks WHERE id = $1', TG_TABLE_SCHEMA)
        INTO bank_dim, bank_model USING NEW.bank_id;

      IF bank_dim IS NULL THEN
        -- Set-once pin. Conditional on still-null so a concurrent pin cannot be
        -- clobbered; re-read to observe the winner.
        EXECUTE format(
          'UPDATE %I.banks SET embedding_dim = $1, embedding_model = $2 WHERE id = $3 AND embedding_dim IS NULL',
          TG_TABLE_SCHEMA
        ) USING NEW.embedded_dim, NEW.embedded_by, NEW.bank_id;

        EXECUTE format('SELECT embedding_dim, embedding_model FROM %I.banks WHERE id = $1', TG_TABLE_SCHEMA)
          INTO bank_dim, bank_model USING NEW.bank_id;
      END IF;

      IF bank_dim <> NEW.embedded_dim OR bank_model IS DISTINCT FROM NEW.embedded_by THEN
        RAISE EXCEPTION
          'bank % is pinned to embedding profile (dim=%, model=%); refusing write with (dim=%, model=%)',
          NEW.bank_id, bank_dim, bank_model, NEW.embedded_dim, NEW.embedded_by
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END;
    $enforce$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER memory_units_enforce_bank_embedding_profile
      BEFORE INSERT OR UPDATE OF embedded_dim, embedded_by ON #{schema}.memory_units
      FOR EACH ROW EXECUTE FUNCTION #{schema}.enforce_bank_embedding_profile();
    """)

    # Backfill existing banks: pin each to the majority (dim, model) among its
    # already-embedded memories, so the invariant holds for pre-existing data.
    execute("""
    UPDATE #{schema}.banks b
    SET embedding_dim = s.embedded_dim, embedding_model = s.embedded_by
    FROM (
      SELECT bank_id, embedded_dim, embedded_by,
             row_number() OVER (PARTITION BY bank_id ORDER BY count(*) DESC) AS rn
      FROM #{schema}.memory_units
      WHERE embedded_dim IS NOT NULL
      GROUP BY bank_id, embedded_dim, embedded_by
    ) s
    WHERE b.id = s.bank_id AND s.rn = 1 AND b.embedding_dim IS NULL;
    """)
  end

  def down do
    schema = ~s("#{prefix() || "public"}")

    execute(
      "DROP TRIGGER IF EXISTS memory_units_enforce_bank_embedding_profile ON #{schema}.memory_units;"
    )

    execute("DROP FUNCTION IF EXISTS #{schema}.enforce_bank_embedding_profile();")

    alter table(:banks) do
      remove(:embedding_dim)
      remove(:embedding_model)
    end
  end
end
