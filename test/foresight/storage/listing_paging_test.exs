defmodule Foresight.Storage.ListingPagingTest do
  @moduledoc """
  list_memories/list_documents page in SQL: one COUNT and one LIMIT/OFFSET read per
  page, instead of loading every row in the bank and slicing in memory. The
  scope_keys/min_score listing filters are derived from the mapped response and keep
  the in-memory path; they must still page correctly.
  """
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

  test "memories and documents page in SQL with a correct total" do
    ctx = %Context{tenant_id: "paging-tenant", mode: :mode_a, bank: "paging-bank"}

    for n <- 1..5 do
      assert {:ok, _} =
               Foresight.retain(ctx, %{
                 "async" => false,
                 "items" => [
                   %{
                     "id" => "doc-#{n}",
                     "document_id" => "doc-#{n}",
                     "content" => "Note number #{n} about the harbour at dusk",
                     "context" => "chat",
                     "tags" => ["n#{n}"]
                   }
                 ]
               })
    end

    assert {:ok, %{"items" => all, "total" => 5, "limit" => 100, "offset" => 0}} =
             Foresight.list_memories(ctx, %{})

    assert length(all) == 5
    all_ids = Enum.map(all, & &1["id"])

    assert {:ok, %{"items" => page1, "total" => 5, "limit" => 2, "offset" => 0}} =
             Foresight.list_memories(ctx, %{"limit" => 2, "offset" => 0})

    assert {:ok, %{"items" => page2, "total" => 5, "limit" => 2, "offset" => 2}} =
             Foresight.list_memories(ctx, %{"limit" => 2, "offset" => 2})

    assert {:ok, %{"items" => page3, "total" => 5, "limit" => 2, "offset" => 4}} =
             Foresight.list_memories(ctx, %{"limit" => 2, "offset" => 4})

    assert Enum.map(page1 ++ page2 ++ page3, & &1["id"]) == all_ids

    assert {:ok, %{"items" => [], "total" => 5, "offset" => 9}} =
             Foresight.list_memories(ctx, %{"limit" => 2, "offset" => 9})

    # The total follows the filters, not the bank.
    assert {:ok, %{"items" => [tagged], "total" => 1}} =
             Foresight.list_memories(ctx, %{"tags" => ["n3"], "limit" => 10})

    assert tagged["tags"] == ["n3"]

    # Negative paging values clamp instead of becoming a bad LIMIT/OFFSET.
    assert {:ok, %{"items" => [], "total" => 5, "limit" => 0, "offset" => 0}} =
             Foresight.list_memories(ctx, %{"limit" => -1, "offset" => -4})

    # Documents: paged in SQL, ordered by id, unit counts for the page only.
    assert {:ok, %{"items" => docs, "total" => 5, "limit" => 2, "offset" => 3}} =
             Foresight.list_documents(ctx, %{"limit" => 2, "offset" => 3})

    assert Enum.map(docs, & &1["id"]) == ["doc-4", "doc-5"]
    assert Enum.all?(docs, &(&1["memory_unit_count"] == 1))

    assert {:ok, %{"items" => [], "total" => 5}} =
             Foresight.list_documents(ctx, %{"limit" => 2, "offset" => 5})
  end

  test "scope_keys and min_score keep the in-memory path and still page" do
    ctx = %Context{tenant_id: "paging-tenant", mode: :mode_a, bank: "paging-scope-bank"}

    for n <- 1..3 do
      assert {:ok, _} =
               Foresight.retain(ctx, %{
                 "async" => false,
                 "items" => [
                   %{"id" => "s-#{n}", "content" => "Scoped note #{n}", "context" => "chat"}
                 ]
               })
    end

    assert {:ok, %{"items" => [], "total" => 0, "limit" => 2, "offset" => 0}} =
             Foresight.list_memories(ctx, %{"scope_keys" => ["no-such-scope"], "limit" => 2})

    # min_score filters on the listed unit's score; a cutoff everything clears pages
    # the full set, a cutoff nothing clears pages an empty one.
    assert {:ok, %{"items" => [_one], "total" => 3, "limit" => 1, "offset" => 1}} =
             Foresight.list_memories(ctx, %{"min_score" => 0.0, "limit" => 1, "offset" => 1})

    assert {:ok, %{"items" => [], "total" => 0, "limit" => 1, "offset" => 1}} =
             Foresight.list_memories(ctx, %{"min_score" => 10.0, "limit" => 1, "offset" => 1})
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
