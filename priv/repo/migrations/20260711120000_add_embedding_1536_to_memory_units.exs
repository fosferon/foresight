defmodule Foresight.Repo.Migrations.AddEmbedding1536ToMemoryUnits do
  use Ecto.Migration

  # Support OpenAI text-embedding-3-small (1536) alongside the local 384/1024 bge
  # dims. The column is nullable and only populated for banks pinned to 1536, so an
  # unused dim costs essentially nothing (NULLs) and its HNSW index builds only over
  # populated rows.
  #
  # 3072 (text-embedding-3-large at full width) is intentionally NOT added here:
  # pgvector's HNSW index for the plain `vector` type is capped at 2000 dimensions,
  # so 3072 requires a `halfvec(3072)` column + halfvec HNSW AND a cast branch in the
  # recall query path. That is tracked as a focused follow-up; 3-large can also be
  # requested at 1536 via the API `dimensions` param in the meantime.
  def change do
    alter table(:memory_units) do
      add(:embedding_1536, :vector, size: 1536)
    end

    create_if_not_exists(
      index(
        :memory_units,
        ["embedding_1536 vector_cosine_ops"],
        name: :memory_units_embedding_1536_vector_cosine_ops_index,
        using: :hnsw
      )
    )
  end
end
