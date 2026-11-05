defmodule Foresight.HTTP.Handlers.VersionHandler do
  @moduledoc false

  import Plug.Conn

  @api_version "0.5.6"

  @spec show(Plug.Conn.t()) :: Plug.Conn.t()
  def show(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(version_payload(config(conn))))
  end

  defp config(conn) do
    conn.private
    |> Map.fetch!(:foresight_config)
  end

  defp version_payload(config) do
    %{
      "api_version" => @api_version,
      "features" => %{
        "observations" => true,
        "mcp" => get_in(config, [:mcp, :enabled]) == true,
        "worker" => get_in(config, [:oban, :enabled]) == true,
        "bank_config_api" => true,
        "file_upload_api" => get_in(config, [:file_ingestion, :enabled]) == true
      }
    }
  end
end
