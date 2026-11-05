defmodule Foresight.Health do
  @moduledoc false

  @spec check(map()) :: map()
  def check(%{repo: %{enabled: true} = repo_config} = config) do
    repo_module = Map.get(repo_config, :module, Foresight.Repo)
    repo_name = Map.get(repo_config, :name, repo_module)
    query_opts = [log: false, timeout: 1_000]

    query_opts =
      if function_exported?(repo_module, :__adapter__, 0) do
        query_opts
      else
        Keyword.put(query_opts, :repo, repo_name)
      end

    base_health =
      case repo_module.query("SELECT 1", [], query_opts) do
        {:ok, %{rows: [[1]]}} ->
          %{"status" => "healthy", "database" => "connected"}

        {:ok, %{rows: rows}} ->
          %{"status" => "unhealthy", "database" => "unexpected response", "rows" => rows}

        {:error, error} ->
          %{"status" => "unhealthy", "database" => "error", "error" => Exception.message(error)}
      end

    merge_posture_status(base_health, config)
  end

  def check(_config) do
    %{"status" => "unhealthy", "reason" => "not_initialized"}
  end

  defp merge_posture_status(base_health, config) do
    if get_in(config, [:tenancy, :posture_monitor, :enabled]) == true do
      posture_monitor =
        get_in(config, [:tenancy, :posture_monitor, :module]) || Foresight.Tenancy.PostureMonitor

      posture_monitor_name =
        get_in(config, [:tenancy, :posture_monitor, :name]) || posture_monitor

      case posture_monitor_status(posture_monitor, posture_monitor_name) do
        %{status: :healthy} = posture ->
          Map.put(base_health, "tenancy_posture", encode_posture(posture))

        %{status: :disabled} ->
          Map.put(base_health, "tenancy_posture", %{"status" => "disabled"})

        %{status: :starting} = posture ->
          unhealthy_with_posture(base_health, encode_posture(posture))

        %{status: :unhealthy} = posture ->
          unhealthy_with_posture(base_health, encode_posture(posture))

        other ->
          unhealthy_with_posture(base_health, %{"status" => inspect(other)})
      end
    else
      base_health
    end
  end

  defp unhealthy_with_posture(base_health, posture) do
    base_health
    |> Map.put("status", "unhealthy")
    |> Map.put("tenancy_posture", posture)
  end

  defp encode_posture(posture) do
    %{
      "status" => posture.status |> to_string(),
      "probe_count" => posture.probe_count,
      "last_run_at" => encode_time(posture.last_run_at),
      "failures" => posture.failures
    }
  end

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp posture_monitor_status(module, server) do
    cond do
      function_exported?(module, :status, 1) -> module.status(server)
      function_exported?(module, :status, 0) -> module.status()
      true -> %{status: :disabled}
    end
  end
end
