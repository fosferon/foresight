defmodule Foresight.Repo.Migrations.AddEmbedding3072HalfvecToMemoryUnits do
  use Ecto.Migration

  # OpenAI text-embedding-3-large at full width (3072). pgvector's HNSW index for the
  # plain `vector` type stops at 2000 dimensions, so this column is `halfvec(3072)`
  # (16-bit floats; the halfvec HNSW cap is 4000) with a halfvec cosine index. The
  # column is nullable and only populated for banks pinned to 3072, like 1024/1536.
  #
  # halfvec arrived in pgvector 0.7.0; the check below turns an obscure "type halfvec
  # does not exist" into a message that names the real requirement.
  @min_pgvector Version.parse!("0.7.0")

  def up do
    ensure_halfvec!()

    alter table(:memory_units) do
      add(:embedding_3072, :halfvec, size: 3072)
    end

    create_if_not_exists(
      index(
        :memory_units,
        ["embedding_3072 halfvec_cosine_ops"],
        name: :memory_units_embedding_3072_halfvec_cosine_ops_index,
        using: :hnsw
      )
    )
  end

  def down do
    drop_if_exists(
      index(:memory_units, [:embedding_3072],
        name: :memory_units_embedding_3072_halfvec_cosine_ops_index
      )
    )

    alter table(:memory_units) do
      remove(:embedding_3072)
    end
  end

  defp ensure_halfvec! do
    %{rows: rows} =
      repo().query!("SELECT extversion FROM pg_extension WHERE extname = 'vector'", [])

    case rows do
      [[version]] when is_binary(version) ->
        if Version.compare(normalize(version), @min_pgvector) == :lt do
          raise "foresight: 3072-dimension embeddings need pgvector >= 0.7.0 (halfvec); " <>
                  "installed: #{version}"
        end

      _ ->
        raise "foresight: the pgvector extension is not installed in this database"
    end
  end

  # pgvector reports plain "0.8.0"; be tolerant of a missing patch component.
  defp normalize(version) do
    case String.split(version, ".") do
      [major, minor] -> Version.parse!("#{major}.#{minor}.0")
      _ -> Version.parse!(version)
    end
  end
end
