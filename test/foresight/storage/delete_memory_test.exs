defmodule Foresight.Storage.DeleteMemoryTest do
  @moduledoc """
  Single-memory delete (a Foresight extension): removes one unit inside the tenant
  scope, takes the observations consolidated from it along, sends their other
  sources back to consolidation, and writes a mutation audit row — so a corpus
  operator never has to go below the API to remove one unit.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 5)
    )

    start_supervised!(Foresight.Repo)
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: Foresight.TestSupport.FakeLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    on_exit(fn ->
      restore(:backend, original_backend)
      restore(:engine, original_engine)
    end)

    :ok
  end

  test "deletes one unit, its derived observations, and records the mutation" do
    bank = "delete-bank"
    ctx = %Context{tenant_id: "delete-tenant", mode: :mode_a, bank: bank}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "id" => "d-1",
                   "content" => "I renewed my passport in Lisbon",
                   "context" => "chat"
                 },
                 %{
                   "id" => "d-2",
                   "content" => "The harbour ferry leaves at dawn",
                   "context" => "chat"
                 }
               ]
             })

    assert {:ok, %{"items" => units, "total" => 2}} = Foresight.list_memories(ctx, %{})
    [target, survivor] = Enum.map(units, & &1["id"])

    # An observation consolidated from both source facts, and one from the survivor
    # alone: the first must go with the target, the second must stay.
    shared = insert_observation!(bank, "Travel plans are afoot", [target, survivor])
    solo = insert_observation!(bank, "Ferries run at dawn", [survivor])

    # Mark the survivor consolidated so the reset is observable.
    Foresight.Repo.update_all(
      from(unit in MemoryUnit, where: unit.id == ^survivor),
      set: [consolidated_at: DateTime.utc_now()]
    )

    assert {:ok, response} = Foresight.delete_memory(ctx, bank, target)

    assert response == %{
             "success" => true,
             "memory_id" => target,
             "memory_units_deleted" => 2,
             "observations_deleted" => 1
           }

    assert {:error, %Foresight.Error{reason: :not_found}} = Foresight.get_memory(ctx, target)
    assert {:error, %Foresight.Error{reason: :not_found}} = Foresight.get_memory(ctx, shared)
    assert {:ok, %{"id" => ^solo}} = Foresight.get_memory(ctx, solo)
    assert {:ok, %{"id" => ^survivor}} = Foresight.get_memory(ctx, survivor)

    # The survivor lost an observation it fed, so it goes back to consolidation.
    assert %MemoryUnit{consolidated_at: nil} = Foresight.Repo.get!(MemoryUnit, survivor)

    # Nothing links to the deleted unit any more.
    assert Foresight.Repo.aggregate(
             from(link in Foresight.Schemas.MemoryUnitEntity,
               where: link.memory_unit_id == ^target
             ),
             :count
           ) == 0

    assert {:ok, %{"items" => [audit]}} =
             Foresight.list_audit_logs(ctx, %{"action" => "delete_memory"})

    assert audit["action"] == "delete_memory"
    assert audit["bank_id"] == bank
    assert audit["request"] == %{"memory_id" => target}
    assert audit["response"]["memory_units_deleted"] == 2

    # Idempotence is not silent: a second delete is a 404, as is a malformed id.
    assert {:error, %Foresight.Error{reason: :not_found}} =
             Foresight.delete_memory(ctx, bank, target)

    assert {:error, %Foresight.Error{reason: :not_found}} =
             Foresight.delete_memory(ctx, bank, "not-a-uuid")

    # The bank is otherwise intact: the survivor and the observation it alone feeds.
    assert {:ok, %{"total" => 2}} = Foresight.list_memories(ctx, %{})
  end

  test "deleting an observation sends its sources back to consolidation and leaves them in place" do
    bank = "delete-observation-bank"
    ctx = %Context{tenant_id: "delete-tenant", mode: :mode_a, bank: bank}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"id" => "o-1", "content" => "Tea with Mara on Tuesday", "context" => "chat"}
               ]
             })

    assert {:ok, %{"items" => [%{"id" => source}]}} = Foresight.list_memories(ctx, %{})

    Foresight.Repo.update_all(
      from(unit in MemoryUnit, where: unit.id == ^source),
      set: [consolidated_at: DateTime.utc_now()]
    )

    observation = insert_observation!(bank, "Mara and tea recur", [source])

    assert {:ok, %{"memory_units_deleted" => 1, "observations_deleted" => 0}} =
             Foresight.delete_memory(ctx, bank, observation)

    assert {:error, %Foresight.Error{reason: :not_found}} = Foresight.get_memory(ctx, observation)
    assert %MemoryUnit{consolidated_at: nil} = Foresight.Repo.get!(MemoryUnit, source)
  end

  test "a unit in another bank is not reachable" do
    ctx_a = %Context{tenant_id: "delete-tenant", mode: :mode_a, bank: "bank-a"}
    ctx_b = %Context{tenant_id: "delete-tenant", mode: :mode_a, bank: "bank-b"}

    assert {:ok, _} =
             Foresight.retain(ctx_a, %{
               "async" => false,
               "items" => [
                 %{"id" => "x-1", "content" => "Private to bank a", "context" => "chat"}
               ]
             })

    assert {:ok, %{"items" => [%{"id" => unit}]}} = Foresight.list_memories(ctx_a, %{})

    assert {:error, %Foresight.Error{reason: :not_found}} =
             Foresight.delete_memory(ctx_b, "bank-b", unit)

    assert {:ok, %{"id" => ^unit}} = Foresight.get_memory(ctx_a, unit)
  end

  defp insert_observation!(bank, content, source_ids) do
    now = DateTime.utc_now()

    %MemoryUnit{}
    |> Ecto.Changeset.change(%{
      bank_id: bank,
      fact_type: :observation,
      content: content,
      context: "consolidation",
      embedded_by: "BAAI/bge-small-en-v1.5",
      embedded_dim: 384,
      source_memory_ids: source_ids,
      mentioned_at: now,
      occurred_at: now
    })
    |> Foresight.Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
