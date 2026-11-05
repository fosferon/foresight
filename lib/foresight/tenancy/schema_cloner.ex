defmodule Foresight.Tenancy.SchemaCloner do
  @moduledoc false

  alias Ecto.Adapters.SQL

  @default_repo Foresight.Repo
  @default_template "foresight_template"
  @default_migration_source "schema_migrations"
  @snapshot_key {__MODULE__, :template_snapshot}
  @schema_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @spec template_schema(keyword()) :: String.t()
  def template_schema(opts \\ []) do
    Keyword.get(opts, :template_prefix, @default_template)
  end

  @spec snapshot_loaded?() :: boolean()
  def snapshot_loaded? do
    :persistent_term.get(@snapshot_key, :missing) != :missing
  end

  @spec invalidate_snapshot() :: :ok
  def invalidate_snapshot do
    :persistent_term.erase(@snapshot_key)
    :ok
  end

  @spec snapshot_template(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def snapshot_template(opts \\ []) do
    repo = Keyword.get(opts, :repo, @default_repo)
    template_prefix = template_schema(opts)

    with :ok <- validate_schema_name(template_prefix),
         {:ok, dump} <- run_pg_dump(repo, template_prefix),
         cleaned = strip_psql_metacommands(dump),
         :ok <- validate_snapshot(cleaned, template_prefix) do
      :persistent_term.put(@snapshot_key, cleaned)
      {:ok, byte_size(cleaned)}
    end
  end

  @spec clone_to(String.t(), keyword()) :: :ok | {:error, term()}
  def clone_to(target_prefix, opts \\ []) when is_binary(target_prefix) do
    repo = Keyword.get(opts, :repo, @default_repo)
    template_prefix = template_schema(opts)

    with :ok <- validate_schema_name(target_prefix),
         :ok <- ensure_snapshot(opts),
         {:ok, dump} <- fetch_snapshot(),
         substituted = substitute_schema(dump, template_prefix, target_prefix),
         :ok <- execute_ddl(repo, substituted),
         :ok <- seed_migration_versions(target_prefix, opts) do
      :telemetry.execute(
        [:foresight, :tenancy, :schema, :clone, :complete],
        %{},
        %{prefix: target_prefix}
      )

      :ok
    end
  end

  @spec seed_migration_versions(String.t(), keyword()) :: :ok | {:error, term()}
  def seed_migration_versions(target_prefix, opts \\ []) when is_binary(target_prefix) do
    repo = Keyword.get(opts, :repo, @default_repo)
    template_prefix = template_schema(opts)
    migration_source = Keyword.get(opts, :migration_source, @default_migration_source)

    with :ok <- validate_schema_name(target_prefix),
         :ok <- validate_schema_name(template_prefix),
         :ok <- validate_schema_name(migration_source),
         {:ok, _} <-
           SQL.query(
             repo,
             """
             INSERT INTO "#{target_prefix}"."#{migration_source}" (version)
             SELECT version
             FROM "#{template_prefix}"."#{migration_source}"
             ON CONFLICT (version) DO NOTHING
             """,
             []
           ) do
      :ok
    end
  end

  defp ensure_snapshot(opts) do
    if snapshot_loaded?() do
      :ok
    else
      case snapshot_template(opts) do
        {:ok, _bytes} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_snapshot do
    case :persistent_term.get(@snapshot_key, :missing) do
      :missing -> {:error, :snapshot_not_loaded}
      dump -> {:ok, dump}
    end
  end

  defp run_pg_dump(repo, template_prefix) do
    case System.find_executable("pg_dump") do
      nil ->
        {:error, :pg_dump_not_found}

      executable ->
        args = [
          "--schema-only",
          "--no-owner",
          "--no-acl",
          "--schema=#{template_prefix}",
          "--dbname=#{dbname(repo)}"
        ]

        case System.cmd(executable, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, code} -> {:error, {:pg_dump_failed, code, output}}
        end
    end
  end

  defp strip_psql_metacommands(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "\\"))
    |> Enum.join("\n")
  end

  defp validate_snapshot(sql, template_prefix) do
    if String.contains?(sql, ~s(CREATE SCHEMA #{template_prefix})) or
         String.contains?(sql, ~s(CREATE SCHEMA "#{template_prefix}")) do
      :ok
    else
      {:error, :snapshot_invalid}
    end
  end

  defp substitute_schema(sql, source_prefix, target_prefix) do
    String.replace(sql, source_prefix, target_prefix)
  end

  defp execute_ddl(repo, sql) do
    case System.find_executable("psql") do
      nil ->
        {:error, :psql_not_found}

      executable ->
        tmp_path =
          Path.join(
            System.tmp_dir!(),
            "foresight-template-clone-#{System.unique_integer([:positive])}.sql"
          )

        File.write!(tmp_path, sql)

        try do
          args = [
            "--single-transaction",
            "--set",
            "ON_ERROR_STOP=1",
            "--dbname=#{dbname(repo)}",
            "--file",
            tmp_path
          ]

          case System.cmd(executable, args, stderr_to_stdout: true) do
            {_output, 0} -> :ok
            {output, code} -> {:error, {:psql_failed, code, output}}
          end
        after
          File.rm(tmp_path)
        end
    end
  end

  defp dbname(repo) do
    config = repo.config()

    cond do
      url = config[:url] ->
        url

      true ->
        username = config[:username] || System.get_env("PGUSER") || System.get_env("USER")
        password = config[:password] || System.get_env("PGPASSWORD") || ""
        hostname = config[:hostname] || "localhost"
        port = config[:port] || 5432
        database = config[:database]
        userinfo = if password == "", do: username, else: "#{username}:#{password}"

        "postgresql://#{userinfo}@#{hostname}:#{port}/#{database}"
    end
  end

  defp validate_schema_name(name) when is_binary(name) do
    if Regex.match?(@schema_pattern, name) do
      :ok
    else
      {:error, :invalid_prefix}
    end
  end
end
