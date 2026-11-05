defmodule Foresight.Evals.Labeling.RepoRuntime do
  @moduledoc false

  alias Ecto.Migrator
  alias Foresight.Profiles.FullMLAuthority

  def start! do
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)

    profile =
      System.get_env()
      |> Map.put("FORESIGHT_FILE_INGESTION", "0")
      |> FullMLAuthority.build()

    repo_opts =
      profile.repo_start_opts
      |> Keyword.put_new(:types, Foresight.PostgrexTypes)
      |> Keyword.put(:timeout, 600_000)
      |> Keyword.put(:queue_target, 10_000)
      |> Keyword.put(:queue_interval, 30_000)
      |> Keyword.put(:log, false)

    Application.put_env(:foresight, Foresight.Repo, repo_opts)
    start_repo(repo_opts)
    migrate!()
  end

  defp start_repo(repo_opts) do
    if Process.whereis(Foresight.Repo) == nil do
      case Foresight.Repo.start_link(repo_opts) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "failed to start Foresight.Repo: #{inspect(reason)}"
      end
    end
  end

  defp migrate! do
    migrations_path = Application.app_dir(:foresight, "priv/repo/migrations")

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    :ok
  end
end
