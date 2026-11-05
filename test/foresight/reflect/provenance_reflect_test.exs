defmodule Foresight.Reflect.ProvenanceReflectTest do
  @moduledoc """
  Verifies provenance-grade grounding: a memory retained with a
  document_ref and a source_location carries that provenance all the way through
  recall into the reflect answer's based_on.memories, so an answer can be traced
  back to (document, exact location) → original file. This is the LongMemEval-style
  provenance link (answer → source document) at the synthetic-test level.

  Real Postgres via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.TestSupport.FakeToolCallingLLM
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
      llm: FakeToolCallingLLM,
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

  test "a grounded memory's source document and location reach based_on.memories" do
    ctx = %Context{tenant_id: "prov-tenant", mode: :mode_a, bank: "prov-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "the Q2 revenue was 4.2 million euros",
                   "context" => "chat",
                   "type" => "world",
                   "document_id" => "report-2023-q2",
                   "source_location" => %{
                     "page" => 4,
                     "section_path" => ["Financials", "Revenue"],
                     "element_type" => "table"
                   }
                 }
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what was Q2 revenue?"})

    memories = get_in(result, ["based_on", "memories"])
    assert is_list(memories) and memories != []

    cited =
      Enum.find(memories, fn m -> m["document_ref"] == "report-2023-q2" end)

    assert cited, "the answer must trace back to its source document"
    assert get_in(cited, ["source_location", "page"]) == 4
    assert get_in(cited, ["source_location", "element_type"]) == "table"
  end

  test "a plain-text memory (no document) carries no provenance and does not break grounding" do
    ctx = %Context{tenant_id: "prov-plain-tenant", mode: :mode_a, bank: "prov-plain-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "the sky is blue", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is the sky?"})

    memories = get_in(result, ["based_on", "memories"])
    assert is_list(memories) and memories != []
    # No document_ref/source_location keys are emitted when there is no provenance.
    assert Enum.all?(memories, fn m ->
             not Map.has_key?(m, "source_location")
           end)
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
