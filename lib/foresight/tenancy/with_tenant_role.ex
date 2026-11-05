defmodule Foresight.Tenancy do
  @moduledoc """
  Public tenant-schema provisioning and execution boundaries.

  Consumers embedding Foresight should use `provision_mode_c_schema/4` to create
  or upgrade a role-neutral Mode C schema. Role and tenant-key lifecycle remains
  an opt-in concern of Foresight's HTTP deployment surface.
  """

  alias Ecto.Adapters.SQL
  alias Foresight.Context
  alias Foresight.Migrations
  alias Foresight.Tenancy.SchemaProvisioner

  @default_repo Foresight.Repo
  @role_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @tenant_prefix_setting "foresight.tenant_prefix"
  @scope_key :foresight_tenant_role_scope
  @mode_b_scope_key :foresight_mode_b_scope

  @doc """
  Installs Foresight's control plane and provisions a Mode C tenant schema.

  `:rls_enabled` is required and must be a boolean. The operation deliberately
  does not create a PostgreSQL role or a tenant API-key record. It delegates the
  schema work to the internal schema provisioner with runtime startup
  disabled and returns that provisioner's result:

      {:ok, %{tenant_id: tenant_id, prefix: prefix, migrated_versions: versions}}

  Additional options are passed to the schema provisioner. `:repo`,
  `:tenant_id`, `:rls_enabled`, and `:start_runtime` cannot be overridden by
  those options.
  """
  @spec provision_mode_c_schema(module(), String.t(), String.t(), keyword()) ::
          {:ok, %{tenant_id: String.t(), prefix: String.t(), migrated_versions: [integer()]}}
          | {:error, term()}
  def provision_mode_c_schema(repo, tenant_id, prefix, opts \\ [])

  def provision_mode_c_schema(repo, tenant_id, prefix, opts)
      when is_atom(repo) and is_binary(tenant_id) and is_binary(prefix) and is_list(opts) do
    with :ok <- validate_mode_c_prefix(prefix),
         {:ok, rls_enabled} <- fetch_rls_enabled(opts),
         {:ok, _install_result} <- Migrations.install(repo, opts) do
      provision_opts =
        opts
        |> Keyword.drop([:tenant_id, :start_runtime])
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:tenant_id, tenant_id)
        |> Keyword.put(:rls_enabled, rls_enabled)
        |> Keyword.put(:start_runtime, false)

      safe_provision(prefix, provision_opts)
    end
  end

  def provision_mode_c_schema(_repo, _tenant_id, _prefix, _opts),
    do: {:error, :invalid_provisioning_arguments}

  @doc "Runs `fun` inside the database scope described by `ctx`."
  @spec with_tenant_role(Context.t(), (-> result)) :: result when result: var
  def with_tenant_role(ctx, fun) when is_function(fun, 0) do
    with_tenant_role(ctx, fun, [])
  end

  @doc """
  Runs `fun` inside the database scope described by `ctx`.

  Options include `:repo` and `:rls_enabled`. An explicitly supplied boolean
  `:rls_enabled` always overrides application configuration.
  """
  @spec with_tenant_role(Context.t(), (-> result), keyword()) :: result when result: var
  def with_tenant_role(%Context{mode: :mode_c, role_name: role_name} = ctx, fun, opts)
      when is_function(fun, 0) do
    repo = Keyword.get(opts, :repo, @default_repo)
    rls_enabled = Keyword.get(opts, :rls_enabled, rls_enabled?())

    cond do
      is_nil(role_name) or role_name == "" ->
        raise ArgumentError, "mode_c context requires role_name"

      not Regex.match?(@role_pattern, role_name) ->
        raise ArgumentError, "invalid tenant role name"

      active_mode_b_prefix() != nil ->
        raise ArgumentError, "with_tenant_role/3 cannot nest Mode C inside an active Mode B scope"

      # Re-entrant case: this process already holds a role-tethered scope.
      # Running the inner body without re-issuing SET ROLE / RESET ROLE keeps
      # the outer scope's tether intact (a nested `after` must not reset the
      # role while the outer scope still believes it is tethered).
      active_role() != nil ->
        active = active_role()

        if active != role_name do
          raise ArgumentError,
                "with_tenant_role/3 cannot nest role #{inspect(role_name)} inside active role #{inspect(active)}"
        end

        with_incremented_depth(fun)

      repo.in_transaction?() ->
        case SQL.query!(repo, "SELECT current_role", []).rows do
          [[^role_name]] ->
            fun.()

          [[current_role]] ->
            raise ArgumentError,
                  "with_tenant_role/3 cannot switch from #{inspect(current_role)} to #{inspect(role_name)} inside an active transaction"
        end

      true ->
        repo.checkout(fn ->
          try do
            SQL.query!(repo, ~s(SET ROLE "#{role_name}"), [])
            maybe_set_rls_scope(repo, ctx, rls_enabled, local: false)
            enter_scope(role_name)
            fun.()
          after
            leave_scope()
            safe_reset_rls_scope(repo, rls_enabled)
            safe_reset_role(repo)
          end
        end)
    end
  end

  def with_tenant_role(%Context{mode: :mode_a} = _ctx, fun, _opts) when is_function(fun, 0),
    do: fun.()

  # Mode B is schema-scoped (Ecto query prefix) with no role tether. Under RLS,
  # FORCE ROW LEVEL SECURITY applies the tenant-scope policy to the table owner too,
  # so Mode B must still set the `foresight.tenant_prefix` GUC or every query would
  # match zero rows. Without RLS this is a plain pass-through.
  def with_tenant_role(%Context{mode: :mode_b, prefix: prefix} = ctx, fun, opts)
      when is_function(fun, 0) do
    repo = Keyword.get(opts, :repo, @default_repo)
    rls_enabled = Keyword.get(opts, :rls_enabled, rls_enabled?())

    cond do
      active_role() != nil ->
        raise ArgumentError, "with_tenant_role/3 cannot nest Mode B inside an active Mode C scope"

      not rls_enabled ->
        fun.()

      not (is_binary(prefix) and prefix != "") ->
        raise ArgumentError, "mode_b RLS requires context prefix"

      active_mode_b_prefix() == prefix ->
        with_incremented_mode_b_depth(fun)

      active_mode_b_prefix() != nil ->
        raise ArgumentError,
              "with_tenant_role/3 cannot nest prefix #{inspect(prefix)} inside active Mode B prefix #{inspect(active_mode_b_prefix())}"

      true ->
        repo.checkout(fn ->
          try do
            maybe_set_rls_scope(repo, ctx, true, local: false)
            enter_mode_b_scope(prefix)
            fun.()
          after
            leave_mode_b_scope()
            safe_reset_rls_scope(repo, true)
          end
        end)
    end
  end

  def with_tenant_role(%Context{mode: mode}, fun, _opts) when is_function(fun, 0) do
    raise ArgumentError,
          "with_tenant_role/3 refuses to run with unknown tenancy mode #{inspect(mode)}; " <>
            "a context must resolve to :mode_a, :mode_b, or :mode_c before scoping"
  end

  @doc """
  Reset all tenant scoping on a freshly checked-out connection.

  Used as a Postgrex `after_connect` hook: clears both the role and the
  session-level `foresight.tenant_prefix` GUC. Both are set non-`LOCAL`, so if a
  scope's `after` cleanup is ever skipped (process killed mid-flight), a stale role
  or prefix could otherwise ride a pooled connection into the next tenant's request.

  Also applies `hnsw.ef_search = 200` for HNSW recall-quality parity with Hindsight
  (`memory_engine.py:1900-1905`) — pgvector's default of 40 under-searches the
  per-fact_type semantic ANN queries. Set per connection (persists for its lifetime),
  and best-effort: a build without the pgvector HNSW GUC must not kill the connection.
  """
  @spec reset_connection(pid()) :: :ok
  def reset_connection(conn) do
    Postgrex.query!(conn, "RESET ROLE", [])
    Postgrex.query!(conn, ~s(RESET "#{@tenant_prefix_setting}"), [])
    # Non-raising (mirrors Hindsight's try/except): tolerate a server without the
    # pgvector HNSW GUC rather than failing every connection checkout.
    _ = Postgrex.query(conn, "SET hnsw.ef_search = 200", [])
    :ok
  end

  # --- re-entrancy scope tracking (per process, i.e. per checked-out connection) ---

  defp active_role do
    case Process.get(@scope_key) do
      {role_name, _depth} -> role_name
      _ -> nil
    end
  end

  defp enter_scope(role_name) do
    Process.put(@scope_key, {role_name, 1})
    :ok
  end

  defp with_incremented_depth(fun) do
    {role_name, depth} = Process.get(@scope_key)
    Process.put(@scope_key, {role_name, depth + 1})

    try do
      fun.()
    after
      case Process.get(@scope_key) do
        {^role_name, current} when current > 1 ->
          Process.put(@scope_key, {role_name, current - 1})

        _ ->
          :ok
      end
    end
  end

  defp leave_scope do
    Process.delete(@scope_key)
    :ok
  end

  defp active_mode_b_prefix do
    case Process.get(@mode_b_scope_key) do
      {prefix, _depth} -> prefix
      _ -> nil
    end
  end

  defp enter_mode_b_scope(prefix) do
    Process.put(@mode_b_scope_key, {prefix, 1})
    :ok
  end

  defp with_incremented_mode_b_depth(fun) do
    {prefix, depth} = Process.get(@mode_b_scope_key)
    Process.put(@mode_b_scope_key, {prefix, depth + 1})

    try do
      fun.()
    after
      case Process.get(@mode_b_scope_key) do
        {^prefix, current} when current > 1 ->
          Process.put(@mode_b_scope_key, {prefix, current - 1})

        _ ->
          :ok
      end
    end
  end

  defp leave_mode_b_scope do
    Process.delete(@mode_b_scope_key)
    :ok
  end

  defp maybe_set_rls_scope(_repo, _ctx, false, _opts), do: :ok

  defp maybe_set_rls_scope(repo, %Context{prefix: prefix}, true, opts)
       when is_binary(prefix) and prefix != "" do
    local? = Keyword.get(opts, :local, true)
    SQL.query!(repo, "SELECT set_config($1, $2, $3)", [@tenant_prefix_setting, prefix, local?])
    :ok
  end

  defp maybe_set_rls_scope(_repo, _ctx, true, _opts) do
    raise ArgumentError, "mode_c RLS requires context prefix"
  end

  defp reset_rls_scope(_repo, false), do: :ok

  defp reset_rls_scope(repo, true) do
    SQL.query!(repo, ~s(RESET "#{@tenant_prefix_setting}"), [])
    :ok
  end

  defp safe_reset_rls_scope(repo, rls_enabled) do
    reset_rls_scope(repo, rls_enabled)
  rescue
    DBConnection.ConnectionError -> :ok
  end

  defp safe_reset_role(repo) do
    SQL.query!(repo, "RESET ROLE", [])
    :ok
  rescue
    DBConnection.ConnectionError -> :ok
  end

  defp rls_enabled? do
    Foresight.Config.resolve()
    |> get_in([:tenancy, :rls_enabled])
    |> Kernel.==(true)
  end

  defp fetch_rls_enabled(opts) do
    case Keyword.fetch(opts, :rls_enabled) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, :rls_enabled, :expected_boolean}}
      :error -> {:error, {:missing_option, :rls_enabled}}
    end
  end

  defp validate_mode_c_prefix("public"), do: {:error, :reserved_tenant_prefix}
  defp validate_mode_c_prefix(_prefix), do: :ok

  defp safe_provision(prefix, opts) do
    SchemaProvisioner.provision(prefix, opts)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
