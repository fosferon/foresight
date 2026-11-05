defmodule Foresight.Storage.RecallCandidatePoolTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Context
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

  test "candidate_pool is default-off and exposes stable eval ids when requested" do
    ctx = %Context{tenant_id: "candidate-pool-tenant", mode: :mode_a, bank: "candidate-pool-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "id" => "session-42",
                   "content" => "I renewed my passport in Lisbon",
                   "context" => "chat",
                   "metadata" => %{"eval_id" => "session-42"}
                 }
               ]
             })

    assert {:ok, default_response} =
             Foresight.recall(ctx, %{"query" => "passport renewal Lisbon", "trace" => true})

    refute Map.has_key?(default_response, "candidate_pool")
    refute Map.has_key?(get_in(default_response, ["trace", "timings_ms"]), "candidate_pool_ms")

    assert {:ok, %{"candidate_pool" => pool}} =
             Foresight.recall(ctx, %{
               "query" => "passport renewal Lisbon",
               "include" => %{"candidate_pool" => %{"top_k" => 20}}
             })

    assert Enum.any?(pool.candidates, &(&1.memory_ref == "session-42"))
    assert pool.dropped == []

    assert {:ok, %{"candidate_pool" => boolean_pool}} =
             Foresight.recall(ctx, %{
               "query" => "passport renewal Lisbon",
               "include" => %{"candidate_pool" => true}
             })

    assert Enum.any?(boolean_pool.candidates, &(&1.memory_ref == "session-42"))

    assert {:ok, disabled_response} =
             Foresight.recall(ctx, %{
               "query" => "passport renewal Lisbon",
               "include" => %{"candidate_pool" => false}
             })

    refute Map.has_key?(disabled_response, "candidate_pool")
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
