defmodule Foresight.Tenancy.Reconciler do
  @moduledoc false

  use GenServer

  require Logger

  alias Foresight.Tenancy.SchemaProvisioner

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run_now(server \\ __MODULE__) do
    GenServer.call(server, :run_now, :infinity)
  end

  @impl true
  def init(opts) do
    send(self(), :reconcile)
    {:ok, opts}
  end

  @impl true
  def handle_info(:reconcile, opts) do
    {:noreply, opts, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, opts) do
    _ = do_reconcile(opts)
    {:noreply, opts}
  end

  @impl true
  def handle_call(:run_now, _from, opts) do
    {:reply, do_reconcile(opts), opts}
  end

  defp do_reconcile(opts) do
    config = Keyword.fetch!(opts, :config)
    tenancy = Map.fetch!(config, :tenancy)
    runtime_registry = Keyword.fetch!(opts, :runtime_registry)
    runtime_supervisor = Keyword.fetch!(opts, :runtime_supervisor)
    repo = get_in(config, [:repo, :module]) || Foresight.Repo

    with {:ok, _template} <-
           SchemaProvisioner.ensure_template(
             repo: repo,
             template_prefix: tenancy.template_prefix
           ),
         {:ok, tracked_tenants} <- SchemaProvisioner.tracked_tenants(repo: repo) do
      tracked_prefixes = MapSet.new(Enum.map(tracked_tenants, & &1.prefix))

      fallback_prefixes =
        ((tenancy.known_prefixes || []) ++ existing_prefixes(repo, tenancy.template_prefix))
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(tracked_prefixes, &1))

      Enum.each(tracked_tenants, fn lifecycle ->
        reconcile_tracked_tenant(lifecycle, repo, tenancy, runtime_registry, runtime_supervisor)
      end)

      Enum.each(fallback_prefixes, fn prefix ->
        reconcile_fallback_prefix(prefix, repo, tenancy, runtime_registry, runtime_supervisor)
      end)

      {:ok,
       %{
         template_prefix: tenancy.template_prefix,
         tracked_prefixes: Enum.map(tracked_tenants, & &1.prefix),
         fallback_prefixes: fallback_prefixes
       }}
    else
      {:error, reason} = error ->
        Logger.warning("[Tenancy.Reconciler] reconcile failed: #{inspect(reason)}")
        error
    end
  end

  defp existing_prefixes(repo, template_prefix) do
    case Ecto.Adapters.SQL.query(
           repo,
           """
           SELECT schema_name
           FROM information_schema.schemata
           WHERE schema_name LIKE 'tenant_%'
             AND schema_name <> $1
           ORDER BY schema_name
           """,
           [template_prefix]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1)
      _ -> []
    end
  end

  defp reconcile_tracked_tenant(
         %{status: status, prefix: prefix, tenant_id: tenant_id},
         repo,
         tenancy,
         runtime_registry,
         runtime_supervisor
       )
       when status in ["provisioning", "provisioned"] do
    case SchemaProvisioner.provision(prefix,
           repo: repo,
           tenant_id: tenant_id,
           template_prefix: tenancy.template_prefix,
           start_runtime: true,
           runtime_registry: runtime_registry,
           runtime_supervisor: runtime_supervisor
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> log_provision_failure(prefix, reason)
    end
  end

  defp reconcile_tracked_tenant(
         %{status: "deleting", prefix: prefix, tenant_id: tenant_id},
         repo,
         tenancy,
         runtime_registry,
         runtime_supervisor
       ) do
    case SchemaProvisioner.drop(prefix,
           repo: repo,
           tenant_id: tenant_id,
           template_prefix: tenancy.template_prefix,
           runtime_registry: runtime_registry,
           runtime_supervisor: runtime_supervisor
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Tenancy.Reconciler] failed to drop #{prefix}: #{inspect(reason)}")
    end
  end

  defp reconcile_tracked_tenant(
         _lifecycle,
         _repo,
         _tenancy,
         _runtime_registry,
         _runtime_supervisor
       ),
       do: :ok

  defp reconcile_fallback_prefix(prefix, repo, tenancy, runtime_registry, runtime_supervisor) do
    case SchemaProvisioner.provision(prefix,
           repo: repo,
           tenant_id: prefix,
           template_prefix: tenancy.template_prefix,
           start_runtime: true,
           runtime_registry: runtime_registry,
           runtime_supervisor: runtime_supervisor
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> log_provision_failure(prefix, reason)
    end
  end

  defp log_provision_failure(prefix, reason) do
    Logger.warning("[Tenancy.Reconciler] failed to provision #{prefix}: #{inspect(reason)}")
  end
end
