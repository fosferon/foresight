defmodule Foresight.Repo.Migrations.CreateMentalModelEmbeddings do
  use Ecto.Migration

  # Mental-model parity with Hindsight: mental models are documents, and
  # Hindsight ranks them for reflect by `embedding <=> query_embedding`. This slim
  # side table (one row per mental-model document) carries that embedding. The
  # vector column is UNSIZED so one column serves every bank width (3072 included:
  # the HNSW cap does not apply, there is no index on the vector, a bank's handful of
  # mental models is scanned exactly). `content_hash` lets the embedding be refreshed
  # lazily when the content or the bank's embedding profile changes. Raw DDL is
  # schema-qualified with prefix() so the provisioner lands it in each tenant schema.
  def up do
    schema = ~s("#{prefix() || "public"}")

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.mental_model_embeddings (
      document_id uuid PRIMARY KEY REFERENCES #{schema}.documents(id) ON DELETE CASCADE,
      bank_id text NOT NULL,
      embedded_dim integer NOT NULL,
      embedded_model text,
      content_hash text NOT NULL,
      embedding vector NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute(
      "CREATE INDEX IF NOT EXISTS mental_model_embeddings_bank_dim_idx ON #{schema}.mental_model_embeddings (bank_id, embedded_dim)"
    )
  end

  def down do
    schema = ~s("#{prefix() || "public"}")
    execute("DROP TABLE IF EXISTS #{schema}.mental_model_embeddings")
  end
end
