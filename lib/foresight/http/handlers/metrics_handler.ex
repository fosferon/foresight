defmodule Foresight.HTTP.Handlers.MetricsHandler do
  @moduledoc false

  import Plug.Conn

  def show(conn) do
    :ok = Foresight.Telemetry.ensure_reporter_started()
    Foresight.Telemetry.dispatch_vm_measurements()

    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape(Foresight.Telemetry.reporter_name()))
  end
end
