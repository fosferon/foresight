defmodule Foresight.Repo.Migrations.AddEmbedding1024ToMemoryUnits do
  use Ecto.Migration

  def change do
    alter table(:memory_units) do
      add :embedding_1024, :vector, size: 1024
    end

    create_if_not_exists(
      index(
        :memory_units,
        ["embedding_1024 vector_cosine_ops"],
        name: :memory_units_embedding_1024_vector_cosine_ops_index,
        using: :hnsw
      )
    )
  end
end
