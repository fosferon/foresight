defmodule Foresight.Tenancy.TenantKeys do
  @moduledoc false

  import Ecto.Query

  alias Foresight.Schemas.TenantKey
  alias Foresight.Tenancy.TenantKeyCache

  @default_repo Foresight.Repo
  @cache_table :foresight_tenant_key_cache
  @default_cache_ttl_ms 60_000

  @spec hash_api_key(String.t()) :: String.t()
  def hash_api_key(api_key) when is_binary(api_key) do
    :crypto.hash(:sha256, api_key)
    |> Base.encode16(case: :lower)
  end

  @spec resolve_role(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_role(slug, api_key, opts \\ []) do
    case resolve(slug, api_key, opts) do
      {:ok, {role_name, _prefix}} -> {:ok, role_name}
      other -> other
    end
  end

  @doc """
  Resolve a `(slug, api_key)` credential to its `{role_name, prefix}`.

  `prefix` may be `nil` for legacy rows written before the registry carried a
  prefix; callers should fall back to the `TenantLifecycle` ledger in that case.
  Role and prefix are cached together so a single lookup (or cache hit) yields both.
  """
  @spec resolve(String.t(), String.t(), keyword()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, term()}
  def resolve(slug, api_key, opts \\ [])
      when is_binary(slug) and is_binary(api_key) do
    repo = Keyword.get(opts, :repo, @default_repo)
    api_key_hash = hash_api_key(api_key)
    cache_ttl_ms = Keyword.get(opts, :cache_ttl_ms, @default_cache_ttl_ms)

    case fetch_cached_role(slug, api_key_hash, cache_ttl_ms) do
      {:ok, {_role_name, _prefix} = resolved} ->
        {:ok, resolved}

      :miss ->
        case repo.one(
               from(tenant_key in TenantKey,
                 where: tenant_key.slug == ^slug and tenant_key.api_key_hash == ^api_key_hash,
                 select: {tenant_key.role_name, tenant_key.prefix}
               )
             ) do
          nil ->
            {:error, :not_found}

          {role_name, prefix} ->
            cache_role(slug, api_key_hash, {role_name, prefix}, cache_ttl_ms)
            {:ok, {role_name, prefix}}
        end
    end
  rescue
    error -> {:error, error}
  end

  @spec put(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, TenantKey.t()} | {:error, term()}
  def put(slug, api_key, role_name, opts \\ [])
      when is_binary(slug) and is_binary(api_key) and is_binary(role_name) do
    put_hashed(slug, hash_api_key(api_key), role_name, opts)
  end

  @spec put_hashed(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, TenantKey.t()} | {:error, term()}
  def put_hashed(slug, api_key_hash, role_name, opts \\ [])
      when is_binary(slug) and is_binary(api_key_hash) and is_binary(role_name) do
    repo = Keyword.get(opts, :repo, @default_repo)

    prefix = Keyword.get(opts, :prefix)

    changeset =
      TenantKey.changeset(%TenantKey{}, %{
        slug: slug,
        api_key_hash: api_key_hash,
        role_name: role_name,
        prefix: prefix
      })

    result =
      repo.insert(
        changeset,
        on_conflict: [set: [role_name: role_name, prefix: prefix, updated_at: DateTime.utc_now()]],
        conflict_target: [:slug, :api_key_hash],
        returning: true
      )

    case result do
      {:ok, tenant_key} ->
        invalidate_hashed(slug, api_key_hash)
        {:ok, tenant_key}

      {:error, _reason} = error ->
        error
    end
  rescue
    error -> {:error, error}
  end

  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(slug, api_key, opts \\ []) when is_binary(slug) and is_binary(api_key) do
    delete_hashed(slug, hash_api_key(api_key), opts)
  end

  @spec delete_hashed(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_hashed(slug, api_key_hash, opts \\ [])
      when is_binary(slug) and is_binary(api_key_hash) do
    repo = Keyword.get(opts, :repo, @default_repo)

    _ =
      repo.delete_all(
        from(tenant_key in TenantKey,
          where: tenant_key.slug == ^slug and tenant_key.api_key_hash == ^api_key_hash
        )
      )

    invalidate_hashed(slug, api_key_hash)
    :ok
  rescue
    error -> {:error, error}
  end

  @spec delete_all(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_all(slug, opts \\ []) when is_binary(slug) do
    repo = Keyword.get(opts, :repo, @default_repo)

    _ =
      repo.delete_all(
        from(tenant_key in TenantKey,
          where: tenant_key.slug == ^slug
        )
      )

    invalidate_slug(slug)
    :ok
  rescue
    error -> {:error, error}
  end

  @spec clear_cache() :: true
  def clear_cache do
    ensure_cache_table!()
    :ets.delete_all_objects(@cache_table)
  end

  @spec invalidate(String.t(), String.t()) :: true
  def invalidate(slug, api_key) when is_binary(slug) and is_binary(api_key) do
    invalidate_hashed(slug, hash_api_key(api_key))
  end

  @spec invalidate_hashed(String.t(), String.t()) :: true
  def invalidate_hashed(slug, api_key_hash)
      when is_binary(slug) and is_binary(api_key_hash) do
    ensure_cache_table!()
    :ets.delete(@cache_table, {slug, api_key_hash})
  end

  @spec invalidate_slug(String.t()) :: true
  def invalidate_slug(slug) when is_binary(slug) do
    ensure_cache_table!()

    :ets.select_delete(@cache_table, [
      {
        {{slug, :"$1"}, :_, :_},
        [],
        [true]
      }
    ])

    true
  end

  @spec error_message(term()) :: String.t()
  def error_message(%{message: message}) when is_binary(message) and message != "", do: message
  def error_message(error), do: Exception.message(error)

  defp fetch_cached_role(_slug, _api_key_hash, cache_ttl_ms) when cache_ttl_ms <= 0, do: :miss

  defp fetch_cached_role(slug, api_key_hash, _cache_ttl_ms) do
    ensure_cache_table!()
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, {slug, api_key_hash}) do
      [{{^slug, ^api_key_hash}, resolved, expires_at_ms}] when expires_at_ms > now_ms ->
        {:ok, resolved}

      [{{^slug, ^api_key_hash}, _resolved, _expires_at_ms}] ->
        :ets.delete(@cache_table, {slug, api_key_hash})
        :miss

      [] ->
        :miss
    end
  end

  defp cache_role(_slug, _api_key_hash, _resolved, cache_ttl_ms) when cache_ttl_ms <= 0, do: :ok

  defp cache_role(slug, api_key_hash, resolved, cache_ttl_ms) do
    ensure_cache_table!()
    expires_at_ms = System.monotonic_time(:millisecond) + cache_ttl_ms
    :ets.insert(@cache_table, {{slug, api_key_hash}, resolved, expires_at_ms})
    :ok
  end

  defp ensure_cache_table! do
    TenantKeyCache.ensure_started!()
  end
end
