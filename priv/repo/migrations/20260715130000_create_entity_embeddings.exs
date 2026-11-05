defmodule Foresight.Repo.Migrations.CreateEntityEmbeddings do
  use Ecto.Migration

  # Store an embedding per entity's canonical name so resolution can
  # surface SEMANTIC variants ("NYC" ↔ "New York City") that are neither substrings nor
  # trigram-similar — recall Hindsight's lexical-only resolver structurally lacks.
  #
  # Slim side table (one row per entity), an UNSIZED vector column so a single column
  # serves any bank's embedding dimension; queries filter by embedded_dim to compare
  # only same-dimension vectors. Raw DDL is schema-qualified with prefix() so the
  # provisioner lands the table in each tenant schema (raw execute does not inherit the
  # migration prefix — same convention as pin_bank_embedding_profile).
  def up do
    schema = ~s("#{prefix() || "public"}")

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.entity_embeddings (
      entity_id uuid PRIMARY KEY REFERENCES #{schema}.entities(id) ON DELETE CASCADE,
      embedded_dim integer NOT NULL,
      embedded_model text,
      embedding vector NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS entity_embeddings_dim_idx ON #{schema}.entity_embeddings (embedded_dim)"
    )
  end

  def down do
    schema = ~s("#{prefix() || "public"}")
    execute("DROP TABLE IF EXISTS #{schema}.entity_embeddings")
  end
end
