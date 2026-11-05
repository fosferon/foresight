defmodule Foresight.Telemetry do
  @moduledoc false

  import Telemetry.Metrics

  @reporter_name Foresight.Prometheus

  def reporter_name, do: @reporter_name

  def metrics do
    [
      counter("foresight.http.requests.total",
        event_name: [:foresight, :http, :request, :stop],
        measurement: :count,
        tags: [:method, :status]
      ),
      distribution("foresight.http.request.duration.seconds",
        event_name: [:foresight, :http, :request, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:method],
        reporter_options: [buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5]]
      ),
      last_value("vm.memory.total.bytes",
        event_name: [:vm, :memory],
        measurement: :total,
        unit: :byte
      ),
      last_value("vm.total_run_queue_lengths.total",
        event_name: [:vm, :total_run_queue_lengths],
        measurement: :total
      )
    ]
  end

  def ensure_reporter_started do
    case Process.whereis(@reporter_name) do
      nil ->
        case TelemetryMetricsPrometheus.Core.start_link(
               name: @reporter_name,
               metrics: metrics(),
               start_async: false
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  def dispatch_vm_measurements do
    :telemetry.execute([:vm, :memory], :erlang.memory() |> Enum.into(%{}), %{})

    :telemetry.execute(
      [:vm, :total_run_queue_lengths],
      %{total: :erlang.statistics(:total_run_queue_lengths)},
      %{}
    )
  end

  def emit_http_request_stop(conn, duration) do
    :ok = ensure_reporter_started()

    :telemetry.execute(
      [:foresight, :http, :request, :stop],
      %{count: 1, duration: duration},
      %{
        method: String.downcase(conn.method || "get"),
        status: Integer.to_string(conn.status || 0)
      }
    )
  end
end
