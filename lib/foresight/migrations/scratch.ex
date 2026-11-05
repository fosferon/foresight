defmodule Foresight.Migrations.Scratch do
  @moduledoc false

  @max_collisions 5

  @doc false
  @spec materialize([%{filename: String.t(), path: String.t()}], String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def materialize(migrations, root \\ System.tmp_dir!()) do
    with {:ok, path} <- create_directory(root, @max_collisions) do
      case link_migrations(migrations, path) do
        :ok ->
          {:ok, path}

        {:error, _reason} = error ->
          File.rm_rf!(path)
          error
      end
    end
  end

  defp create_directory(_root, 0), do: {:error, :scratch_directory_collisions}

  defp create_directory(root, attempts) do
    suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    path = Path.join(root, "foresight-control-migrations-#{suffix}")

    case File.mkdir(path) do
      :ok -> {:ok, path}
      {:error, :eexist} -> create_directory(root, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  defp link_migrations(migrations, path) do
    Enum.reduce_while(migrations, :ok, fn migration, :ok ->
      case File.ln_s(migration.path, Path.join(path, migration.filename)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
