defmodule Foresight.Tenancy.ModeCTenantLifecycle do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias Ecto.Adapters.SQL
  alias Foresight.Schemas.TenantLifecycle
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.Tenancy.TenantKeys

  @default_repo Foresight.Repo
  @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/
  @api_key_hash_pattern ~r/^[a-f0-9]{64}$/

  @spec provision(String.t(), map(), keyword()) ::
          {:ok, %{tenant_id: String.t(), prefix: String.t(), role_name: String.t()}}
          | {:error, term()}
  def provision(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) and is_map(attrs) do
    repo = Keyword.get(opts, :repo, @default_repo)
    rls_enabled = Keyword.get(opts, :rls_enabled, false)

    with {:ok, prefix} <- fetch_identifier(attrs, "prefix"),
         {:ok, role_name} <- fetch_identifier(attrs, "role_name"),
         {:ok, api_key_hash} <- fetch_api_key_hash(attrs),
         {:ok, _} <-
           SchemaProvisioner.provision(prefix,
             repo: repo,
             rls_enabled: rls_enabled,
             tenant_id: tenant_id
           ),
         :ok <- ensure_role(repo, role_name),
         :ok <- grant_role_access(repo, prefix, role_name),
         {:ok, _tenant_key} <-
           TenantKeys.put_hashed(tenant_id, api_key_hash, role_name, repo: repo, prefix: prefix),
         :ok <- merge_lifecycle_metadata(repo, tenant_id, %{"role_name" => role_name}) do
      {:ok, %{tenant_id: tenant_id, prefix: prefix, role_name: role_name}}
    end
  end

  @spec fetch(String.t(), keyword()) ::
          {:ok,
           %{
             tenant_id: String.t(),
             prefix: String.t(),
             status: String.t(),
             role_name: String.t() | nil,
             last_error: String.t() | nil,
             last_provisioned_at: DateTime.t() | nil,
             last_deleted_at: DateTime.t() | nil,
             inserted_at: DateTime.t() | nil,
             updated_at: DateTime.t() | nil,
             metadata: map()
           }}
          | {:error, :not_found}
  def fetch(tenant_id, opts \\ []) when is_binary(tenant_id) do
    repo = Keyword.get(opts, :repo, @default_repo)

    case repo.one(from(lifecycle in TenantLifecycle, where: lifecycle.tenant_id == ^tenant_id)) do
      nil ->
        {:error, :not_found}

      %TenantLifecycle{} = lifecycle ->
        {:ok,
         %{
           tenant_id: lifecycle.tenant_id,
           prefix: lifecycle.prefix,
           status: lifecycle.status,
           role_name: get_in(lifecycle.metadata || %{}, ["role_name"]),
           last_error: lifecycle.last_error,
           last_provisioned_at: lifecycle.last_provisioned_at,
           last_deleted_at: lifecycle.last_deleted_at,
           inserted_at: lifecycle.inserted_at,
           updated_at: lifecycle.updated_at,
           metadata: lifecycle.metadata || %{}
         }}
    end
  end

  @spec drop(String.t(), map(), keyword()) ::
          {:ok, %{tenant_id: String.t(), prefix: String.t(), role_name: String.t()}}
          | {:error, term()}
  def drop(tenant_id, attrs, opts \\ []) when is_binary(tenant_id) and is_map(attrs) do
    repo = Keyword.get(opts, :repo, @default_repo)
    rls_enabled = Keyword.get(opts, :rls_enabled, false)

    with {:ok, prefix} <- fetch_identifier(attrs, "prefix"),
         {:ok, role_name} <- fetch_identifier(attrs, "role_name"),
         {:ok, _api_key_hash} <- fetch_api_key_hash(attrs),
         :ok <- TenantKeys.delete_all(tenant_id, repo: repo),
         :ok <- maybe_warn_on_role_drop(drop_role(repo, prefix, role_name), tenant_id, role_name),
         :ok <-
           SchemaProvisioner.drop(prefix,
             repo: repo,
             rls_enabled: rls_enabled,
             tenant_id: tenant_id
           ),
         :ok <- merge_lifecycle_metadata(repo, tenant_id, %{"role_name" => role_name}) do
      {:ok, %{tenant_id: tenant_id, prefix: prefix, role_name: role_name}}
    end
  end

  defp fetch_identifier(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if Regex.match?(@identifier_pattern, value) do
          {:ok, value}
        else
          {:error, {:invalid_request, "#{key} must be a valid SQL identifier"}}
        end

      _ ->
        {:error, {:invalid_request, "#{key} must be a valid SQL identifier"}}
    end
  end

  defp fetch_api_key_hash(attrs) do
    case Map.get(attrs, "api_key_hash") do
      value when is_binary(value) ->
        if Regex.match?(@api_key_hash_pattern, value) do
          {:ok, value}
        else
          {:error, {:invalid_request, "api_key_hash must be a lowercase SHA-256 hex digest"}}
        end

      _ ->
        {:error, {:invalid_request, "api_key_hash must be a lowercase SHA-256 hex digest"}}
    end
  end

  defp ensure_role(repo, role_name) do
    case SQL.query(
           repo,
           """
           SELECT 1
           FROM pg_roles
           WHERE rolname = $1
           """,
           [role_name]
         ) do
      {:ok, %{num_rows: 0}} ->
        case SQL.query(repo, ~s|CREATE ROLE "#{role_name}" NOINHERIT|, []) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grant_role_access(repo, prefix, role_name) do
    statements = [
      # Make the connecting login a member of the tenant role so `SET ROLE` works
      # without a superuser login. Under a least-privileged app login this is what
      # tethers the connection to the tenant role; under a superuser login it is a
      # harmless no-op. Paired with `REVOKE ... FROM CURRENT_USER` in do_drop_role/3.
      ~s|GRANT "#{role_name}" TO CURRENT_USER|,
      ~s|GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role_name}"|,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      ~s|ALTER DEFAULT PRIVILEGES IN SCHEMA "#{prefix}" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "#{role_name}"|,
      ~s|ALTER DEFAULT PRIVILEGES IN SCHEMA "#{prefix}" GRANT USAGE, SELECT ON SEQUENCES TO "#{role_name}"|
    ]

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case SQL.query(repo, statement, []) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp drop_role(repo, prefix, role_name) do
    if role_exists?(repo, role_name) do
      do_drop_role(repo, prefix, role_name)
    else
      :ok
    end
  end

  defp do_drop_role(repo, prefix, role_name) do
    statements = [
      ~s|ALTER DEFAULT PRIVILEGES IN SCHEMA "#{prefix}" REVOKE ALL PRIVILEGES ON TABLES FROM "#{role_name}"|,
      ~s|ALTER DEFAULT PRIVILEGES IN SCHEMA "#{prefix}" REVOKE ALL PRIVILEGES ON SEQUENCES FROM "#{role_name}"|,
      ~s|REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA "#{prefix}" FROM "#{role_name}"|,
      ~s|REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA "#{prefix}" FROM "#{role_name}"|,
      ~s|REVOKE ALL PRIVILEGES ON SCHEMA "#{prefix}" FROM "#{role_name}"|,
      ~s|REVOKE "#{role_name}" FROM CURRENT_USER|,
      ~s|DROP OWNED BY "#{role_name}"|,
      ~s|DROP ROLE IF EXISTS "#{role_name}"|
    ]

    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      case SQL.query(repo, statement, []) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          if drop_role_dependency_warning?(statement, reason) do
            {:halt, {:warning, reason}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp role_exists?(repo, role_name) do
    case SQL.query(
           repo,
           """
           SELECT 1
           FROM pg_roles
           WHERE rolname = $1
           """,
           [role_name]
         ) do
      {:ok, %{num_rows: 0}} -> false
      {:ok, _} -> true
      {:error, _} -> true
    end
  end

  defp maybe_warn_on_role_drop(:ok, _tenant_id, _role_name), do: :ok

  defp maybe_warn_on_role_drop({:warning, reason}, tenant_id, role_name) do
    Logger.warning(
      "Mode C tenant drop left role #{role_name} in place for #{tenant_id}: #{inspect(reason)}"
    )

    :ok
  end

  defp maybe_warn_on_role_drop({:error, reason}, _tenant_id, _role_name), do: {:error, reason}

  defp drop_role_dependency_warning?(
         "DROP ROLE IF EXISTS " <> _rest,
         %{postgres: %{code: :dependent_objects_still_exist}}
       ),
       do: true

  defp drop_role_dependency_warning?(_statement, _reason), do: false

  defp merge_lifecycle_metadata(repo, tenant_id, metadata) do
    case repo.one(from(lifecycle in TenantLifecycle, where: lifecycle.tenant_id == ^tenant_id)) do
      nil ->
        :ok

      %TenantLifecycle{} = lifecycle ->
        merged_metadata = Map.merge(lifecycle.metadata || %{}, metadata)

        lifecycle
        |> TenantLifecycle.changeset(%{metadata: merged_metadata})
        |> repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    error -> {:error, error}
  end
end
