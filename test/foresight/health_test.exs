defmodule Foresight.HealthTest do
  use ExUnit.Case, async: true

  defmodule DriftMonitor do
    def status do
      %{
        status: :unhealthy,
        last_run_at: ~U[2026-06-27 07:00:00Z],
        probe_count: 1,
        failures: [%{tenant_id: "tenant-a", message: "role drift"}]
      }
    end
  end

  test "returns not initialized when repo is disabled" do
    assert Foresight.Health.check(%{repo: %{enabled: false}}) == %{
             "status" => "unhealthy",
             "reason" => "not_initialized"
           }
  end

  test "returns connected when repo query succeeds" do
    name = Module.concat(__MODULE__, HealthyRepo)
    start_supervised!({Foresight.TestSupport.FakeRepo, name: name})

    assert Foresight.Health.check(%{
             repo: %{enabled: true, module: Foresight.TestSupport.FakeRepo, name: name}
           }) == %{"status" => "healthy", "database" => "connected"}
  end

  test "returns error details when repo query fails" do
    name = Module.concat(__MODULE__, BrokenRepo)
    error = RuntimeError.exception("db down")

    start_supervised!({Foresight.TestSupport.FakeRepo, name: name, result: {:error, error}})

    assert Foresight.Health.check(%{
             repo: %{enabled: true, module: Foresight.TestSupport.FakeRepo, name: name}
           }) == %{"status" => "unhealthy", "database" => "error", "error" => "db down"}
  end

  test "marks health unhealthy when posture monitor reports drift" do
    name = Module.concat(__MODULE__, RepoWithDrift)
    start_supervised!({Foresight.TestSupport.FakeRepo, name: name})

    assert Foresight.Health.check(%{
             repo: %{enabled: true, module: Foresight.TestSupport.FakeRepo, name: name},
             tenancy: %{posture_monitor: %{enabled: true, module: DriftMonitor}}
           }) == %{
             "status" => "unhealthy",
             "database" => "connected",
             "tenancy_posture" => %{
               "status" => "unhealthy",
               "probe_count" => 1,
               "last_run_at" => "2026-06-27T07:00:00Z",
               "failures" => [%{tenant_id: "tenant-a", message: "role drift"}]
             }
           }
  end
end
