defmodule Foresight.HTTP.RequestContext.DefaultResolver do
  @moduledoc """
  Resolves a request into a tenancy `Context`, and is the authorization authority.

  Two credential classes:

    * **Service (admin)** — the presented bearer equals the configured service key.
      A service caller may assert `x-foresight-role` / `x-foresight-prefix` headers
      (still constrained by any `auth.tenant_scopes` allowlist). This is the ops /
      test impersonation path.

    * **Tenant** — any other presented bearer. Its role is resolved from the
      tenant-key registry keyed on `(tenant_id, api_key)`, and its schema prefix is
      resolved from the `TenantLifecycle` ledger keyed on `tenant_id`. Client-supplied
      `x-foresight-role` / `x-foresight-prefix` headers are **ignored** for tenant
      callers — this is what prevents a client from asserting another tenant's role.

  Anything that resolves to neither a valid service credential nor a registered tenant
  key is rejected (`401`). There is no silent downgrade to a broader scope.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @behaviour Foresight.TenantResolver
  @schema_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.Tenancy.ModeCTenantLifecycle
  alias Foresight.Tenancy.TenantKeys

  @impl true
  def resolve(%{conn: conn}, opts) do
    tenant_id = header_value(conn, opts, :tenant_id, "x-foresight-tenant-id")
    api_key = conn.assigns[:api_key]
    config = conn.private[:foresight_config] || %{}
    service? = Auth.service_credential?(config, api_key)

    with {:ok, role_name, prefix} <-
           resolve_identity(conn, opts, config, tenant_id, api_key, service?),
         :ok <- validate_scoped_request(conn, tenant_id, role_name, prefix),
         :ok <- validate_role_name(role_name),
         :ok <- validate_schema_name(prefix),
         :ok <- validate_scope_allowlist(conn, tenant_id, role_name, prefix) do
      {:ok,
       %Context{
         tenant_id: tenant_id || "default",
         mode: resolve_mode(role_name, prefix),
         bank: "default",
         role_name: role_name,
         prefix: prefix,
         embedding_dim: nil
       }}
    end
  end

  # Service (admin) caller: trust the asserted role/prefix headers. The allowlist
  # (`validate_scope_allowlist`) still constrains which values a given key may assert.
  defp resolve_identity(conn, opts, _config, _tenant_id, _api_key, true) do
    role_name = header_value(conn, opts, :role_name, "x-foresight-role")
    prefix = header_value(conn, opts, :prefix, "x-foresight-prefix")
    {:ok, role_name, prefix}
  end

  # Tenant caller with a tenant-scoping request: role + prefix come from the server,
  # never from the client. Fails closed on any miss.
  defp resolve_identity(_conn, _opts, config, tenant_id, api_key, false)
       when is_binary(tenant_id) and tenant_id != "" do
    cond do
      is_nil(api_key) or api_key == "" ->
        {:error,
         Error.new(:unauthorized, %{message: "tenant-scoped request requires authentication"})}

      true ->
        repo = tenant_key_repo(config)

        with {:ok, role_name, prefix} <- registry_identity(tenant_id, api_key, repo) do
          {:ok, role_name, prefix}
        end
    end
  end

  # Tenant caller with no tenant-scoping headers: not authorized for any scope.
  defp resolve_identity(_conn, _opts, _config, _tenant_id, _api_key, false) do
    {:error, Error.new(:unauthorized, %{message: "valid service or tenant credential required"})}
  end

  # Role and (when present) prefix come from the registry in one lookup. Legacy rows
  # without a stored prefix fall back to the TenantLifecycle ledger.
  defp registry_identity(tenant_id, api_key, repo) do
    case TenantKeys.resolve(tenant_id, api_key, repo: repo) do
      {:ok, {role_name, prefix}}
      when is_binary(role_name) and role_name != "" and is_binary(prefix) and prefix != "" ->
        {:ok, role_name, prefix}

      {:ok, {role_name, _nil_prefix}} when is_binary(role_name) and role_name != "" ->
        with {:ok, prefix} <- lifecycle_prefix(tenant_id, repo) do
          {:ok, role_name, prefix}
        end

      {:ok, _} ->
        {:error, Error.new(:unauthorized, %{message: "credential does not resolve to a role"})}

      {:error, :not_found} ->
        {:error, Error.new(:unauthorized, %{message: "unknown tenant credential"})}

      {:error, error} ->
        {:error,
         Error.new(:service_unavailable, %{
           message: "tenant key registry lookup failed",
           detail: TenantKeys.error_message(error)
         })}
    end
  end

  defp lifecycle_prefix(tenant_id, repo) do
    case ModeCTenantLifecycle.fetch(tenant_id, repo: repo) do
      {:ok, %{prefix: prefix}} when is_binary(prefix) and prefix != "" ->
        {:ok, prefix}

      _ ->
        {:error, Error.new(:unauthorized, %{message: "tenant is not provisioned for isolation"})}
    end
  end

  defp header_value(conn, opts, key, default_header) do
    header_name =
      opts
      |> Keyword.get(:headers, %{})
      |> Map.new()
      |> Map.get(key, default_header)

    case get_req_header(conn, header_name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end

  defp validate_scoped_request(conn, tenant_id, role_name, prefix) do
    cond do
      tenant_id == nil and role_name == nil and prefix == nil ->
        :ok

      conn.assigns[:api_key] in [nil, ""] ->
        {:error,
         Error.new(:unauthorized, %{message: "tenant-scoping headers require authentication"})}

      tenant_id == nil and (role_name != nil or prefix != nil) ->
        {:error,
         Error.new(:invalid_request, %{
           message: "tenant-scoping headers require x-foresight-tenant-id"
         })}

      true ->
        :ok
    end
  end

  defp validate_scope_allowlist(conn, tenant_id, role_name, prefix) do
    case tenant_scope_for(conn) do
      nil ->
        :ok

      scope ->
        with :ok <-
               validate_allowed_value(
                 tenant_id,
                 Map.get(scope, :tenant_ids) || Map.get(scope, "tenant_ids"),
                 "tenant"
               ),
             :ok <-
               validate_allowed_value(
                 role_name,
                 Map.get(scope, :roles) || Map.get(scope, "roles"),
                 "role"
               ),
             :ok <-
               validate_allowed_value(
                 prefix,
                 Map.get(scope, :prefixes) || Map.get(scope, "prefixes"),
                 "prefix"
               ) do
          :ok
        end
    end
  end

  defp tenant_scope_for(conn) do
    config = conn.private[:foresight_config] || %{}
    tenant_scopes = get_in(config, [:auth, :tenant_scopes]) || %{}
    api_key = conn.assigns[:api_key]

    cond do
      api_key in [nil, ""] -> nil
      is_map(tenant_scopes) -> Map.get(tenant_scopes, api_key)
      true -> nil
    end
  end

  defp validate_allowed_value(nil, _allowed, _kind), do: :ok
  defp validate_allowed_value(_value, nil, _kind), do: :ok
  defp validate_allowed_value(_value, [], _kind), do: unauthorized_scope_claim()

  defp validate_allowed_value(value, allowed, kind) when is_list(allowed) do
    if value in allowed do
      :ok
    else
      unauthorized_scope_claim(kind)
    end
  end

  defp resolve_mode(nil, prefix) when is_binary(prefix) and prefix != "", do: :mode_b

  defp resolve_mode(role_name, prefix)
       when is_binary(role_name) and is_binary(prefix),
       do: :mode_c

  defp resolve_mode(_role_name, _prefix), do: :mode_a

  defp validate_schema_name(nil), do: :ok

  defp validate_schema_name(prefix) when is_binary(prefix) do
    if Regex.match?(@schema_pattern, prefix) do
      :ok
    else
      {:error, Error.new(:invalid_request, %{message: "invalid tenant schema prefix"})}
    end
  end

  defp validate_role_name(nil), do: :ok

  defp validate_role_name(role_name) when is_binary(role_name) do
    if Regex.match?(@schema_pattern, role_name) do
      :ok
    else
      {:error, Error.new(:invalid_request, %{message: "invalid tenant role name"})}
    end
  end

  defp unauthorized_scope_claim(kind \\ "tenant") do
    {:error,
     Error.new(:unauthorized, %{
       message: "requested #{kind} scope is not allowed for this credential"
     })}
  end

  defp tenant_key_repo(config) do
    case get_in(config, [:repo, :public]) do
      %{enabled: true} = repo_config ->
        Map.get(repo_config, :module, Foresight.PublicRepo)

      _ ->
        get_in(config, [:repo, :module]) || Foresight.Repo
    end
  end
end
