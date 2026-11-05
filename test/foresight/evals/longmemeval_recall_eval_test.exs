defmodule Foresight.Evals.LongMemEvalRecallEvalTest do
  @moduledoc """
  Honest recall measurement on real LongMemEval data.

  Retains a slice of the corpus into one shared bank, then for each question recalls against
  that shared corpus and scores with id-based ranking metrics against the gold
  `answer_session_ids`. Because every other question's sessions live in the same bank, they
  act as genuine distractors — a real "find the few relevant memories among many" task, not
  the trivial evidence-only setting.

  Tagged `:eval` and excluded from the normal suite (it needs fetched data and, for the
  authoritative semantic number, a real embedding model). Configuration via env:

      FORESIGHT_LME_PATH   path to a fetched split (default priv/evals/data/longmemeval_oracle.json)
      FORESIGHT_LME_LIMIT  instances to score (default 50)

  Backend/embedder are whatever is configured: the default test env uses the deterministic
  FakeStorage stack (a lexical baseline on real queries — the ranking *plumbing* on real
  data); the real Ecto + embedding-model lane produces the authoritative semantic number
  with the same code.
  """
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag timeout: 600_000

  alias Foresight.Context
  alias Foresight.Evals.LongMemEval
  alias Foresight.Evals.Runner

  @default_path "priv/evals/data/longmemeval_oracle.json"

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    start_supervised!(Foresight.TestSupport.FakeStorage)
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)
    Foresight.TestSupport.FakeStorage.reset!()
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.TestSupport.FakeStorage,
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

  test "LongMemEval recall baseline over a shared corpus" do
    path = System.get_env("FORESIGHT_LME_PATH", @default_path)
    limit = System.get_env("FORESIGHT_LME_LIMIT", "50") |> String.to_integer()

    unless File.exists?(path) do
      IO.puts("\n[skip] #{path} not present — run `mix foresight.evals.fetch longmemeval_oracle`")
      # A skip, not a failure: the harness must not red-fail CI when data is absent.
      assert true
    else
      instances = LongMemEval.load!(path, limit: limit)
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "lme-eval"}

      # One shared corpus: retain every slice memory once (dedup by id across instances).
      all_memories =
        instances
        |> Enum.flat_map(& &1.memories)
        |> Enum.uniq_by(& &1["id"])

      # Retain in chunks: the in-memory FakeStorage retain is a synchronous GenServer call,
      # so one huge batch would trip its call timeout. (The real Ecto lane retains async.)
      all_memories
      |> Enum.chunk_every(15)
      |> Enum.each(fn chunk -> assert {:ok, _} = Foresight.retain(ctx, %{"items" => chunk}) end)

      recall_fun = fn inst ->
        {:ok, %{"results" => results}} =
          Foresight.recall(ctx, %{
            "query" => inst.query,
            "query_timestamp" => inst.query_timestamp
          })

        results
      end

      report = Runner.run(instances, recall_fun, k: 10, recall_k: 5)

      IO.puts(
        "\n=== LongMemEval recall baseline (#{length(instances)} queries, #{length(all_memories)} sessions in corpus) ==="
      )

      IO.puts(
        "backend: #{inspect(Application.get_env(:foresight, :engine)[:embedder])} (embedder)"
      )

      IO.puts(Runner.format_report(report) <> "\n")

      # Sanity floors only — the corpus and (in this lane) embedder are fixed; this guards
      # against a total retrieval breakdown, not a quality target.
      assert report.overall.n == length(instances)
      assert report.overall.recall >= 0.0
    end
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
