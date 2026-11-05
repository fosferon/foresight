defmodule Foresight.Storage.RecallConnectionScopeTest do
  @moduledoc """
  Recall must not hold the tenant's database connection while the embedder and the
  reranker run. In Mode C a tenant scope is a checked-out connection (SET ROLE), and
  the pool's checkout timeout counts everything inside it: a cross-encoder taking
  seconds on a large bank used to turn into a dropped connection and a failed
  recall. The model calls now run between scoped phases, so inside them nothing is
  checked out — which this test observes from inside the embedder and reranker.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  @role "recall_scope_reader"

  defmodule ProbeEmbedder do
    @moduledoc false
    @behaviour Foresight.Embedder

    @impl true
    def dimension(opts), do: Foresight.TestSupport.FakeEmbedder.dimension(opts)

    @impl true
    def embed(text, opts) do
      send(self(), {:embedder_checked_out, Foresight.Repo.checked_out?()})
      Foresight.TestSupport.FakeEmbedder.embed(text, opts)
    end
  end

  defmodule ProbeReranker do
    @moduledoc false
    @behaviour Foresight.Reranker

    @impl true
    def rerank(query, candidates, opts) do
      send(self(), {:reranker_checked_out, Foresight.Repo.checked_out?(), length(candidates)})
      Foresight.TestSupport.FakeReranker.rerank(query, candidates, opts)
    end
  end

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 5,
        after_connect: {Foresight.Tenancy, :reset_connection, []}
      )
    )

    start_supervised!(Foresight.Repo)
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    # A Mode C tenant role over the public schema: enough for SET ROLE to be real
    # (the scope is a checked-out connection) without provisioning a tenant schema.
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "#{@role}"|, [])
    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "#{@role}" NOINHERIT|, [])
    SQL.query!(Foresight.Repo, ~s|GRANT "#{@role}" TO CURRENT_USER|, [])
    SQL.query!(Foresight.Repo, ~s|GRANT USAGE ON SCHEMA public TO "#{@role}"|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "#{@role}"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "#{@role}"|,
      []
    )

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
      embedder: ProbeEmbedder,
      reranker: ProbeReranker,
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

  test "the embedder and reranker run with no connection checked out under a Mode C scope" do
    ctx = %Context{
      tenant_id: "scope-tenant",
      mode: :mode_c,
      role_name: @role,
      bank: "scope-bank"
    }

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "id" => "s-1",
                   "content" => "I renewed my passport in Lisbon",
                   "context" => "chat"
                 },
                 %{
                   "id" => "s-2",
                   "content" => "The harbour ferry leaves at dawn",
                   "context" => "chat"
                 }
               ]
             })

    # Retain embeds too; only the recall-time probes matter here.
    flush_probe_messages()

    assert {:ok, response} =
             Foresight.recall(ctx, %{"query" => "passport renewal Lisbon", "trace" => true})

    assert_received {:embedder_checked_out, false}
    assert_received {:reranker_checked_out, false, rerank_count} when rerank_count > 0

    # The scoped phases still ran under the tenant role, and the enrichment phase
    # still decorated the results.
    assert response["trace"]["db_role"] == @role or
             Enum.any?(
               Map.values(response["trace"]["strategies"] || %{}),
               &(is_map(&1) and &1["db_role"] == @role)
             )

    assert [%{"entities" => entities} | _] = response["results"]
    assert is_list(entities)
    assert is_map(response["entities"])

    # The always-on stats name the rerank window and what went through it.
    assert %{
             "candidates" => candidates,
             "rerank_window" => window,
             "rerank_candidates" => ^rerank_count,
             "results" => results,
             "rerank_ms" => rerank_ms,
             "retrieval_ms" => retrieval_ms,
             "total_ms" => total_ms
           } = response["stats"]

    assert candidates >= rerank_count and rerank_count >= results and results > 0
    assert window > 0
    assert is_integer(rerank_ms) and is_integer(retrieval_ms) and is_integer(total_ms)
  end

  test "Mode A recall reports the same stats and keeps the connection-free model calls" do
    ctx = %Context{tenant_id: "scope-tenant", mode: :mode_a, bank: "scope-bank-a"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"id" => "a-1", "content" => "Tea with Mara on Tuesday", "context" => "chat"}
               ]
             })

    flush_probe_messages()

    assert {:ok, %{"stats" => stats, "results" => [_ | _]}} =
             Foresight.recall(ctx, %{"query" => "tea with Mara"})

    assert_received {:reranker_checked_out, false, _count}
    assert stats["results"] >= 1
  end

  defp flush_probe_messages do
    receive do
      {:embedder_checked_out, _} -> flush_probe_messages()
      {:reranker_checked_out, _, _} -> flush_probe_messages()
    after
      0 -> :ok
    end
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
