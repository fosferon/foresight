defmodule Foresight.HTTP.Handlers.HealthHandler do
  @moduledoc false

  import Plug.Conn

  @spec show(Plug.Conn.t()) :: Plug.Conn.t()
  def show(conn) do
    health =
      conn.private
      |> Map.fetch!(:foresight_config)
      |> health_check()

    status = if health["status"] == "healthy", do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(health))
  end

  defp health_check(config) do
    checker = get_in(config, [:health, :checker]) || Foresight.Health
    checker.check(config)
  end
end
