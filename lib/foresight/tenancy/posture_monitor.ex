defmodule Foresight.Tenancy.PostureMonitor do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Foresight.Context
  alias Foresight.Schemas.TenantKey
  alias Foresight.Schemas.TenantLifecycle
  alias Foresight.Tenancy

  @tenant_prefix_setting "foresight.tenant_prefix"
  @default_interval_ms :timer.minutes(1)

  defstruct [
    :config,
    :repo,
    :interval_ms,
    :last_run_at,
    :probe_count,
    status: :starting,
    failures: []
  ]

  @type t :: %__MODULE__{}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{status: :disabled}
  end

  def run_now(server \\ __MODULE__) do
    GenServer.call(server, :run_now, :infinity)
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    repo = Keyword.get(opts, :repo, get_in(config, [:repo, :module]) || Foresight.Repo)

    state = %__MODULE__{
      config: config,
      repo: repo,
      interval_ms:
        get_in(config, [:tenancy, :posture_monitor, :interval_ms]) || @default_interval_ms
    }

    {:ok, state, {:continue, :initial_probe}}
  end

  @impl true
  def handle_continue(:initial_probe, state) do
    {:noreply, schedule_next(run_probe(state))}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_payload(state), state}
  end

  def handle_call(:run_now, _from, state) do
    next_state = run_probe(state)
    {:reply, status_payload(next_state), schedule_next(next_state)}
  end

  @impl true
  def handle_info(:probe, state) do
    {:noreply, schedule_next(run_probe(state))}
  end

  defp run_probe(state) do
    {status, failures, probe_count} = probe_all(state.repo, state.config)

    %{
      state
      | status: status,
        failures: failures,
        probe_count: probe_count,
        last_run_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp schedule_next(state) do
    Process.send_after(self(), :probe, state.interval_ms)
    state
  end

  defp status_payload(state) do
    %{
      status: state.status,
      last_run_at: state.last_run_at,
      probe_count: state.probe_count,
      failures: state.failures
    }
  end

  defp probe_all(repo, config) do
    rls_enabled = get_in(config, [:tenancy, :rls_enabled]) == true

    probes =
      repo.all(
        from(tk in TenantKey,
          join: tl in TenantLifecycle,
          on: tl.tenant_id == tk.slug,
          where: tl.status == "provisioned",
          distinct: [tk.slug, tl.prefix, tk.role_name],
          select: %{tenant_id: tk.slug, prefix: tl.prefix, role_name: tk.role_name}
        )
      )

    failures =
      Enum.flat_map(probes, fn probe ->
        case probe_one(repo, probe, rls_enabled) do
          :ok -> []
          {:error, failure} -> [failure]
        end
      end)

    status =
      cond do
        failures != [] -> :unhealthy
        true -> :healthy
      end

    {status, failures, length(probes)}
  rescue
    error ->
      {:unhealthy,
       [
         %{
           tenant_id: nil,
           prefix: nil,
           role_name: nil,
           message: Exception.message(error)
         }
       ], 0}
  end

  defp probe_one(repo, %{tenant_id: tenant_id, prefix: prefix, role_name: role_name}, rls_enabled) do
    ctx = %Context{
      tenant_id: tenant_id,
      mode: :mode_c,
      bank: "__posture__",
      prefix: prefix,
      role_name: role_name
    }

    case Tenancy.with_tenant_role(
           ctx,
           fn ->
             current_role = query_value!(repo, "SELECT current_role", [])

             current_prefix =
               query_value!(repo, "SELECT current_setting($1, true)", [@tenant_prefix_setting])

             %{current_role: current_role, current_prefix: current_prefix}
           end,
           repo: repo,
           rls_enabled: rls_enabled
         ) do
      {:error, reason} ->
        {:error, failure(tenant_id, prefix, role_name, inspect(reason))}

      %{current_role: ^role_name, current_prefix: ^prefix} ->
        # Compare against the connection's own login role, not a hardcoded "postgres".
        # RESET ROLE returns to session_user, whatever that is — pinning the literal meant
        # the monitor could only ever report healthy when the app logged in as postgres,
        # i.e. as a superuser. That structurally forbade the least-privilege posture the
        # the earlier remediation depends on, since RLS is owner-bypassed for a superuser
        # .
        # Also assert the tenant_prefix GUC cleared. Role and prefix are set together and
        # must clear together; checking only the role would miss a connection returned to
        # the pool still carrying a tenant's prefix (an audit finding).
        case SQL.query(
               repo,
               "SELECT current_role, session_user, current_setting($1, true)",
               [@tenant_prefix_setting]
             ) do
          {:ok, %{rows: [[role, role, leftover]]}}
          when is_binary(role) and leftover in [nil, ""] ->
            :ok

          {:ok, %{rows: [[role, role, leftover]]}} when is_binary(role) ->
            {:error,
             failure(
               tenant_id,
               prefix,
               role_name,
               "tenant prefix leaked after probe: #{inspect(leftover)}"
             )}

          {:ok, %{rows: [[current_role, _session_user, _leftover]]}} ->
            {:error,
             failure(
               tenant_id,
               prefix,
               role_name,
               "role reset drift detected after probe: #{inspect(current_role)}"
             )}

          {:error, reason} ->
            {:error, failure(tenant_id, prefix, role_name, Exception.message(reason))}
        end

      %{current_role: current_role, current_prefix: current_prefix} ->
        {:error,
         failure(
           tenant_id,
           prefix,
           role_name,
           "probe mismatch: role=#{inspect(current_role)} prefix=#{inspect(current_prefix)}"
         )}
    end
  rescue
    error ->
      {:error, failure(tenant_id, prefix, role_name, Exception.message(error))}
  end

  defp query_value!(repo, sql, params) do
    case SQL.query!(repo, sql, params).rows do
      [[value]] -> value
      rows -> raise "unexpected probe rows: #{inspect(rows)}"
    end
  end

  defp failure(tenant_id, prefix, role_name, message) do
    %{
      tenant_id: tenant_id,
      prefix: prefix,
      role_name: role_name,
      message: message
    }
  end
end
