defmodule ForesightTest do
  use ExUnit.Case

  setup do
    original = Application.get_env(:foresight, :backend)
    Application.put_env(:foresight, :backend, Foresight.TestSupport.NoopBackend)

    on_exit(fn ->
      if original do
        Application.put_env(:foresight, :backend, original)
      else
        Application.delete_env(:foresight, :backend)
      end
    end)

    :ok
  end

  test "delegates operations through the configured backend" do
    ctx = %Foresight.Context{tenant_id: "tenant-1", mode: :mode_a, bank: "fosferon"}

    assert {:ok, %{op: :retain, payload: %{items: []}}} =
             Foresight.retain(ctx, %{items: []})

    assert {:ok, %{op: :retain_files, payload: %{"files" => [%{"filename" => "a.pdf"}]}}} =
             Foresight.retain_files(ctx, %{"files" => [%{"filename" => "a.pdf"}]})

    assert {:ok, %{op: :recall, query: "where?"}} = Foresight.recall(ctx, "where?")
    assert {:ok, %{op: :reflect, query: "why?"}} = Foresight.reflect(ctx, "why?")

    assert {:ok, %{op: :list_memories, params: %{"limit" => 5}}} =
             Foresight.list_memories(ctx, %{"limit" => 5})

    assert {:ok, %{op: :list_entities, params: %{}}} = Foresight.list_entities(ctx)
    assert {:ok, %{op: :bank_profile, id: "fosferon"}} = Foresight.bank_profile(ctx, "fosferon")

    assert {:ok, %{op: :update_bank_disposition, id: "fosferon"}} =
             Foresight.update_bank_disposition(ctx, "fosferon", %{"skepticism" => 4})

    assert {:ok, %{op: :add_bank_background, id: "fosferon", mission: "hello"}} =
             Foresight.add_bank_background(ctx, "fosferon", "hello")

    assert {:ok, %{op: :list_documents, params: %{}}} = Foresight.list_documents(ctx)

    assert {:ok, %{op: :list_audit_logs, params: %{"limit" => 5}}} =
             Foresight.list_audit_logs(ctx, %{"limit" => 5})

    assert {:ok, %{op: :audit_log_stats, params: %{"period" => "7d"}}} =
             Foresight.audit_log_stats(ctx, %{"period" => "7d"})

    assert {:ok,
            %{op: :memories_timeseries, id: "fosferon", period: "30d", time_field: "mentioned_at"}} =
             Foresight.memories_timeseries(ctx, "fosferon", "30d", "mentioned_at")

    assert {:ok, %{op: :list_operations, params: %{"limit" => 5}}} =
             Foresight.list_operations(ctx, %{"limit" => 5})

    assert {:ok, %{op: :get_operation, id: "42"}} = Foresight.get_operation(ctx, "42")

    assert {:ok, %{op: :recover_consolidation, bank_id: "fosferon", retried_count: 0}} =
             Foresight.recover_consolidation(ctx, "fosferon")
  end

  test "returns a uniform error when no backend implementation exists" do
    Application.put_env(:foresight, :backend, Foresight.Backend.Noop)

    ctx = %Foresight.Context{tenant_id: "tenant-1", mode: :mode_a, bank: "fosferon"}

    assert {:error, %Foresight.Error{reason: :not_implemented, detail: %{operation: "recall"}}} =
             Foresight.recall(ctx, "query")

    assert {:error,
            %Foresight.Error{reason: :not_implemented, detail: %{operation: "retain_files"}}} =
             Foresight.retain_files(ctx, %{"files" => [%{"filename" => "a.pdf"}]})
  end
end
