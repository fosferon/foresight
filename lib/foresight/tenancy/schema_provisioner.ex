defmodule Foresight.Tenancy.SchemaProvisioner do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Migrations.Manifest
  alias Foresight.Schemas.TenantLifecycle
  alias Foresight.Tenancy.RuntimeSupervisor
  alias Foresight.Tenancy.SchemaCloner
  alias Foresight.Tenancy.SchemaLock

  @default_repo Foresight.Repo
  @default_template "foresight_template"
  @tenant_rls_policy "foresight_tenant_scope"
  @tenant_prefix_setting "foresight.tenant_prefix"
  @schema_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @tenant_migration_cache_root_key {__MODULE__, :tenant_migration_cache_root}
  @tenant_migration_cache_lock {__MODULE__, :tenant_migration_cache}

  @spec provision(String.t(), keyword()) ::
          {:ok, %{prefix: String.t(), migrated_versions: [integer()]}} | {:error, term()}
  def provision(prefix, opts \\ [])

  def provision(prefix, opts) when is_binary(prefix) do
    SchemaLock.with_slug(prefix, fn ->
      do_provision(prefix, opts)
    end)
  end

  def provision(_prefix, _opts), do: {:error, :invalid_prefix}

  @spec tracked_tenants(keyword()) :: {:ok, [TenantLifecycle.t()]} | {:error, term()}
  def tracked_tenants(opts \\ []) do
    repo = Keyword.get(opts, :repo, @default_repo)

    {:ok, repo.all(from(lifecycle in TenantLifecycle, order_by: [asc: lifecycle.prefix]))}
  rescue
    error -> {:error, error}
  end

  @spec ensure_template(keyword()) ::
          {:ok, %{prefix: String.t(), migrated_versions: [integer()]}} | {:error, term()}
  def ensure_template(opts \\ []) do
    template_prefix = Keyword.get(opts, :template_prefix, @default_template)

    SchemaLock.with_slug(template_prefix, fn ->
      repo = Keyword.get(opts, :repo, @default_repo)

      with {:ok, result} <- do_provision(template_prefix, Keyword.put(opts, :repo, repo)),
           {:ok, _bytes} <-
             SchemaCloner.snapshot_template(
               repo: repo,
               template_prefix: template_prefix
             ) do
        {:ok, result}
      end
    end)
  end

  @spec drop(String.t(), keyword()) :: :ok | {:error, term()}
  def drop(prefix, opts \\ []) when is_binary(prefix) do
    SchemaLock.with_slug(prefix, fn ->
      repo = Keyword.get(opts, :repo, @default_repo)
      template_prefix = Keyword.get(opts, :template_prefix, @default_template)
      tenant_id = Keyword.get(opts, :tenant_id, prefix)

      with :ok <- validate_prefix(prefix),
           :ok <- put_lifecycle(repo, tenant_id, prefix, "deleting", template_prefix),
           :ok <- maybe_stop_runtime(prefix, opts),
           {:ok, _} <- SQL.query(repo, ~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE), []),
           :ok <-
             put_lifecycle(
               repo,
               tenant_id,
               prefix,
               "deleted",
               template_prefix,
               last_error: nil,
               last_deleted_at: DateTime.utc_now()
             ) do
        :ok
      else
        {:error, reason} = error ->
          _ =
            put_lifecycle(
              repo,
              tenant_id,
              prefix,
              "deleting",
              template_prefix,
              last_error: Exception.message(normalize_error(reason))
            )

          error
      end
    end)
  end

  @spec schema_exists?(String.t(), keyword()) :: boolean()
  def schema_exists?(prefix, opts \\ []) when is_binary(prefix) do
    repo = Keyword.get(opts, :repo, @default_repo)

    case SQL.query(
           repo,
           """
           SELECT EXISTS(
             SELECT 1
             FROM information_schema.schemata
             WHERE schema_name = $1
           )
           """,
           [prefix]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp do_provision(prefix, opts) do
    repo = Keyword.get(opts, :repo, @default_repo)
    migrations_path = Keyword.get(opts, :migrations_path, migrations_path())
    template_prefix = Keyword.get(opts, :template_prefix, @default_template)
    tenant_id = Keyword.get(opts, :tenant_id, prefix)

    with :ok <- validate_prefix(prefix),
         :ok <- put_lifecycle(repo, tenant_id, prefix, "provisioning", template_prefix),
         {:ok, migrated_versions} <-
           populate_schema(repo, prefix, migrations_path, template_prefix, opts),
         :ok <- sync_rls(repo, prefix, opts),
         :ok <- maybe_start_runtime(prefix, opts),
         :ok <-
           put_lifecycle(
             repo,
             tenant_id,
             prefix,
             "provisioned",
             template_prefix,
             last_error: nil,
             last_provisioned_at: DateTime.utc_now(),
             last_deleted_at: nil
           ) do
      {:ok, %{prefix: prefix, migrated_versions: migrated_versions, tenant_id: tenant_id}}
    else
      {:error, reason} = error ->
        _ =
          put_lifecycle(
            repo,
            tenant_id,
            prefix,
            "provisioning",
            template_prefix,
            last_error: Exception.message(normalize_error(reason))
          )

        error
    end
  end

  defp populate_schema(repo, prefix, migrations_path, template_prefix, _opts) do
    cond do
      schema_exists?(prefix, repo: repo) ->
        with {:ok, migrated_versions, _apps} <- run_migrations(repo, migrations_path, prefix) do
          {:ok, migrated_versions}
        end

      template_clone_ready?(repo, template_prefix, migrations_path) ->
        case SchemaCloner.clone_to(
               prefix,
               repo: repo,
               template_prefix: template_prefix
             ) do
          :ok ->
            {:ok, migrated_versions(repo, prefix)}

          {:error, reason} ->
            _ = SQL.query(repo, ~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE), [])

            with {:ok, _} <- SQL.query(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"), []),
                 {:ok, migrated_versions, _apps} <- run_migrations(repo, migrations_path, prefix) do
              {:ok, migrated_versions}
            else
              {:error, migration_reason} -> {:error, {:clone_failed, reason, migration_reason}}
            end
        end

      true ->
        with {:ok, _} <- SQL.query(repo, ~s(CREATE SCHEMA IF NOT EXISTS "#{prefix}"), []),
             {:ok, migrated_versions, _apps} <- run_migrations(repo, migrations_path, prefix) do
          {:ok, migrated_versions}
        end
    end
  end

  defp run_migrations(repo, migrations_path, prefix) do
    effective_path = tenant_migrations_path(migrations_path, prefix)

    try do
      with_module_conflict_ignored(effective_path != migrations_path, fn ->
        Migrator.with_repo(repo, fn repo ->
          migrated_versions =
            Migrator.run(repo, effective_path, :up, all: true, prefix: prefix)

          migrated_versions
        end)
      end)
    after
      cleanup_temp_migrations_path(migrations_path, effective_path)
    end
  end

  defp with_module_conflict_ignored(false, fun), do: fun.()

  defp with_module_conflict_ignored(true, fun) when is_function(fun, 0) do
    previous = Map.get(Code.compiler_options(), :ignore_module_conflict, false)
    Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(ignore_module_conflict: previous)
    end
  end

  defp migrated_versions(repo, prefix) do
    case SQL.query(
           repo,
           ~s(SELECT version FROM "#{prefix}"."schema_migrations" ORDER BY version),
           []
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1)
      _ -> []
    end
  end

  defp template_clone_ready?(repo, template_prefix, migrations_path) do
    if schema_exists?(template_prefix, repo: repo) do
      expected = expected_versions(migrations_path, template_prefix)
      actual = MapSet.new(migrated_versions(repo, template_prefix))
      legacy_public_data = migration_versions(Manifest.files(:public_data))

      actual == expected or actual == MapSet.union(expected, legacy_public_data)
    else
      false
    end
  end

  defp expected_versions(migrations_path, prefix) do
    migrations_path
    |> migration_files_for_prefix(prefix)
    |> Enum.map(&Path.basename/1)
    |> migration_versions()
  end

  defp migration_versions(filenames) do
    filenames
    |> Enum.map(fn filename ->
      filename
      |> String.split("_", parts: 2)
      |> hd()
      |> String.to_integer()
    end)
    |> MapSet.new()
  end

  defp validate_prefix(prefix) do
    if Regex.match?(@schema_pattern, prefix) do
      :ok
    else
      {:error, :invalid_prefix}
    end
  end

  defp maybe_start_runtime(prefix, opts) do
    if Keyword.get(opts, :start_runtime, false) do
      RuntimeSupervisor.ensure_started(
        prefix,
        runtime_registry: Keyword.fetch!(opts, :runtime_registry),
        runtime_supervisor: Keyword.get(opts, :runtime_supervisor, RuntimeSupervisor)
      )
      |> case do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_stop_runtime(prefix, opts) do
    if runtime_registry = Keyword.get(opts, :runtime_registry) do
      RuntimeSupervisor.stop_prefix(
        prefix,
        runtime_registry: runtime_registry,
        runtime_supervisor: Keyword.get(opts, :runtime_supervisor, RuntimeSupervisor)
      )
    else
      :ok
    end
  end

  defp sync_rls(repo, prefix, opts) do
    case tenant_tables(repo, prefix) do
      {:ok, tables} ->
        tables
        |> Enum.reject(&(&1 == "schema_migrations"))
        |> Enum.each(fn table ->
          if rls_enabled?(opts) do
            enable_rls(repo, prefix, table)
          else
            disable_rls(repo, prefix, table)
          end
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tenant_tables(repo, prefix) do
    SQL.query(
      repo,
      """
      SELECT tablename
      FROM pg_tables
      WHERE schemaname = $1
      ORDER BY tablename
      """,
      [prefix]
    )
    |> case do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &hd/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enable_rls(repo, prefix, table) do
    SQL.query!(repo, ~s(ALTER TABLE "#{prefix}"."#{table}" ENABLE ROW LEVEL SECURITY), [])
    # FORCE so the policy also applies to the table owner. Without this, any query
    # running as the owning (e.g. superuser/migration) role bypasses RLS entirely,
    # which would make the tenant-scope policy decorative on the very paths that
    # matter most (mode_a/mode_b, migrations, reconciler).
    SQL.query!(repo, ~s(ALTER TABLE "#{prefix}"."#{table}" FORCE ROW LEVEL SECURITY), [])

    SQL.query!(
      repo,
      ~s(DROP POLICY IF EXISTS "#{@tenant_rls_policy}" ON "#{prefix}"."#{table}"),
      []
    )

    SQL.query!(
      repo,
      ~s|CREATE POLICY "#{@tenant_rls_policy}" ON "#{prefix}"."#{table}" USING (current_setting('#{@tenant_prefix_setting}', true) = '#{prefix}') WITH CHECK (current_setting('#{@tenant_prefix_setting}', true) = '#{prefix}')|,
      []
    )
  end

  defp disable_rls(repo, prefix, table) do
    SQL.query!(
      repo,
      ~s(DROP POLICY IF EXISTS "#{@tenant_rls_policy}" ON "#{prefix}"."#{table}"),
      []
    )

    SQL.query!(repo, ~s(ALTER TABLE "#{prefix}"."#{table}" DISABLE ROW LEVEL SECURITY), [])
  end

  defp rls_enabled?(opts) do
    case Keyword.fetch(opts, :rls_enabled) do
      {:ok, enabled} ->
        enabled == true

      :error ->
        Foresight.Config.resolve()
        |> get_in([:tenancy, :rls_enabled])
        |> Kernel.==(true)
    end
  end

  defp migrations_path do
    Application.app_dir(:foresight, "priv/repo/migrations")
  end

  defp tenant_migrations_path(migrations_path, "public"), do: migrations_path

  defp tenant_migrations_path(migrations_path, _prefix) do
    case Manifest.validate(migrations_path) do
      :ok ->
        filenames = Manifest.files(:tenant)
        cached_tenant_migrations_dir(migrations_path, filenames)

      {:error, reason} ->
        raise "invalid Foresight migration manifest: #{inspect(reason)}"
    end
  end

  defp cached_tenant_migrations_dir(migrations_path, filenames) do
    migrations_path = Path.expand(migrations_path)

    digest =
      [
        migrations_path
        | Enum.map(filenames, fn filename ->
            [filename, File.read!(Path.join(migrations_path, filename))]
          end)
      ]
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    :global.trans({@tenant_migration_cache_lock, self()}, fn ->
      cache_root = tenant_migration_cache_root()
      temp_dir = Path.join(cache_root, digest)
      File.mkdir_p!(temp_dir)

      Enum.each(filenames, fn filename ->
        source = Path.join(migrations_path, filename)
        target = Path.join(temp_dir, filename)
        ensure_migration_link!(source, target)
      end)

      temp_dir
    end)
  end

  defp tenant_migration_cache_root do
    case :persistent_term.get(@tenant_migration_cache_root_key, nil) do
      nil ->
        suffix = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
        root = Path.join(System.tmp_dir!(), "foresight-tenant-migrations-#{suffix}")
        File.mkdir!(root)
        File.chmod!(root, 0o700)
        :persistent_term.put(@tenant_migration_cache_root_key, root)
        root

      root ->
        case File.lstat(root) do
          {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 ->
            root

          _ ->
            raise "Foresight migration cache root is missing or unsafe"
        end
    end
  end

  defp ensure_migration_link!(source, target) do
    case File.read_link(target) do
      {:ok, ^source} ->
        :ok

      {:ok, _other_source} ->
        raise "Foresight migration cache identity collision"

      {:error, :enoent} ->
        File.ln_s!(source, target)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read link", path: target
    end
  end

  defp cleanup_temp_migrations_path(original_path, original_path), do: :ok

  defp cleanup_temp_migrations_path(_original_path, _temp_path), do: :ok

  defp migration_files_for_prefix(migrations_path, "public") do
    migrations_path
    |> Path.join("*.exs")
    |> Path.wildcard()
  end

  defp migration_files_for_prefix(migrations_path, _prefix) do
    case Manifest.validate(migrations_path) do
      :ok -> Enum.map(Manifest.files(:tenant), &Path.join(migrations_path, &1))
      {:error, reason} -> raise "invalid Foresight migration manifest: #{inspect(reason)}"
    end
  end

  defp put_lifecycle(repo, tenant_id, prefix, status, template_prefix, attrs \\ [])

  defp put_lifecycle(_repo, _tenant_id, prefix, _status, template_prefix, _attrs)
       when prefix == template_prefix,
       do: :ok

  defp put_lifecycle(repo, tenant_id, prefix, status, _template_prefix, attrs) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.merge(%{
        tenant_id: tenant_id,
        prefix: prefix,
        status: status
      })

    changeset = TenantLifecycle.changeset(%TenantLifecycle{}, attrs)

    case repo.insert(
           changeset,
           on_conflict: {:replace_all_except, [:tenant_id, :inserted_at]},
           conflict_target: [:tenant_id]
         ) do
      {:ok, _lifecycle} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    error -> {:error, error}
  end

  defp normalize_error(reason) when is_exception(reason), do: reason
  defp normalize_error(reason), do: RuntimeError.exception(inspect(reason))
end
