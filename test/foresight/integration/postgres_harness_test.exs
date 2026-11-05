defmodule Foresight.Integration.PostgresHarnessTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Foresight.Context
  alias Foresight.Schemas.AuditLog
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.Delivery
  alias Foresight.Schemas.Webhook
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.TestSupport.PostgresHarness
  alias Oban.Job

  import Ecto.Query

  @moduletag :tier2

  defmodule FakeDoclingConverter do
    @behaviour Foresight.DocumentConverter

    @impl true
    def convert(%{"filename" => filename}, _opts) do
      {:ok,
       %{
         text: "converted body from #{filename}",
         title: "Converted #{filename}",
         metadata: %{"source" => "fake-docling"},
         content_type: "application/pdf"
       }}
    end
  end

  defmodule CapturedReflectCalls do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def reset! do
      Agent.update(__MODULE__, fn _ -> [] end)
    end

    def record(entry) do
      Agent.update(__MODULE__, fn entries -> [entry | entries] end)
    end

    def entries do
      Agent.get(__MODULE__, &Enum.reverse/1)
    end
  end

  defmodule CaptureReflectLLM do
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, response_module, opts) do
      CapturedReflectCalls.record(%{
        prompt: prompt,
        messages: messages,
        response_module: response_module,
        opts: opts
      })

      Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
    end

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
    end
  end

  defmodule CaptureReflectDbScopeLLM do
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, response_module, opts) do
      %{rows: [[db_role]]} = SQL.query!(Foresight.Repo, "SELECT current_role", [])

      %{rows: [[db_tenant_prefix]]} =
        SQL.query!(Foresight.Repo, "SELECT current_setting($1, true)", ["foresight.tenant_prefix"])

      CapturedReflectCalls.record(%{
        prompt: prompt,
        messages: messages,
        response_module: response_module,
        opts: opts,
        db_role: db_role,
        db_tenant_prefix: db_tenant_prefix
      })

      Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
    end

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
    end
  end

  defmodule CheckoutProbeReflectLLM do
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, response_module, opts) do
      repo = Application.fetch_env!(:foresight, :reflect_probe_repo)

      probe =
        Task.async(fn ->
          SQL.query(repo, "SELECT 1", [], timeout: 50)
        end)

      Process.sleep(100)
      probe_result = Task.await(probe, 1_000)

      CapturedReflectCalls.record(%{
        prompt: prompt,
        messages: messages,
        response_module: response_module,
        opts: opts,
        probe_result: probe_result
      })

      Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
    end

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
    end
  end

  defmodule SlowReflectLLM do
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, response_module, opts) do
      Process.sleep(100)
      Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
    end

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      Process.sleep(100)
      Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
    end
  end

  defmodule ExitingReflectLLM do
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(_prompt, _messages, _response_module, _opts) do
      exit(:simulated_llm_exit)
    end

    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts) do
      exit(:simulated_llm_exit)
    end
  end

  defmodule SingleConnRepo do
    use Ecto.Repo,
      otp_app: :foresight,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule FakeWebhookHTTPClient do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{responses: [], calls: []} end, name: __MODULE__)
    end

    def reset! do
      Agent.update(__MODULE__, fn _ -> %{responses: [], calls: []} end)
    end

    def put_responses(responses) when is_list(responses) do
      Agent.update(__MODULE__, fn state -> %{state | responses: responses} end)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end

    def post(url, payload, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: responses, calls: calls} = state ->
        {response, remaining} =
          case responses do
            [first | tail] -> {first, tail}
            [] -> {{:ok, %{status: 200, body: "ok"}}, []}
          end

        next_state = %{
          state
          | responses: remaining,
            calls: [%{url: url, payload: payload, opts: opts} | calls]
        }

        {response, next_state}
      end)
    end
  end

  defmodule RoleAwareWebhookHTTPClient do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def reset! do
      Agent.update(__MODULE__, fn _ -> [] end)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse/1)
    end

    def post(url, payload, opts) do
      %{rows: [[db_role]]} = SQL.query!(Foresight.Repo, "SELECT current_role", [])

      Agent.update(__MODULE__, fn calls ->
        [%{url: url, payload: payload, opts: opts, db_role: db_role} | calls]
      end)

      {:ok, %{status: 200, body: "ok"}}
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
        pool_size: 10
      )
    )

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(Foresight.Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    start_supervised!(
      {Oban,
       name: Foresight.Oban,
       repo: Foresight.Repo,
       peer: false,
       plugins: false,
       testing: :manual,
       queues: [foresight_retain: 2, foresight_consolidate: 2, foresight_webhook_delivery: 2]}
    )

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    {:ok, harness: harness}
  end

  setup do
    if Process.whereis(CapturedReflectCalls) do
      CapturedReflectCalls.reset!()
    else
      start_supervised!(CapturedReflectCalls)
    end

    if Process.whereis(FakeWebhookHTTPClient) do
      FakeWebhookHTTPClient.reset!()
    else
      start_supervised!(FakeWebhookHTTPClient)
    end

    if Process.whereis(RoleAwareWebhookHTTPClient) do
      RoleAwareWebhookHTTPClient.reset!()
    else
      start_supervised!(RoleAwareWebhookHTTPClient)
    end

    :ok
  end

  test "boots against a real postgres instance and applies migrations", %{harness: harness} do
    assert {:ok, %{rows: [[1]]}} = SQL.query(Foresight.Repo, "SELECT 1", [])

    assert {:ok, %{rows: [[database]]}} =
             SQL.query(Foresight.Repo, "SELECT current_database()", [])

    assert database == harness.database

    assert {:ok,
            %{
              rows: [
                [banks],
                [memory_units],
                [documents],
                [audit_log],
                [webhooks],
                [file_storage],
                [deliveries]
              ]
            }} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'banks'
               )
               UNION ALL
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'memory_units'
               )
               UNION ALL
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'documents'
               )
               UNION ALL
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'audit_log'
               )
               UNION ALL
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'webhooks'
               )
               UNION ALL
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'file_storage'
               )
               UNION ALL
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_name = 'deliveries'
               )
               """,
               []
             )

    assert banks == true
    assert memory_units == true
    assert documents == true
    assert audit_log == true
    assert webhooks == true
    assert file_storage == true
    assert deliveries == true
  end

  test "memory_units fact_type constraint matches head schema contract" do
    assert {:ok, %{rows: [[definition]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT pg_get_constraintdef(oid)
               FROM pg_constraint
               WHERE conname = 'memory_units_fact_type_check'
                 AND conrelid = 'public.memory_units'::regclass
               """,
               []
             )

    assert definition =~ "world"
    assert definition =~ "experience"
    assert definition =~ "observation"
    refute definition =~ "mental_model"
    refute definition =~ "opinion"
  end

  test "file retain persists file storage and stays recallable with provenance" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_file_ingestion = Application.get_env(:foresight, :file_ingestion)

    upload_path =
      Path.join(
        System.tmp_dir!(),
        "foresight-file-retain-#{System.unique_integer([:positive])}.pdf"
      )

    File.write!(upload_path, "binary fixture body")

    on_exit(fn ->
      File.rm(upload_path)

      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end

      if original_file_ingestion do
        Application.put_env(:foresight, :file_ingestion, original_file_ingestion)
      else
        Application.delete_env(:foresight, :file_ingestion)
      end
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

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

    Application.put_env(:foresight, :file_ingestion,
      enabled: true,
      converter: FakeDoclingConverter,
      converter_opts: []
    )

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "file-bank"}

    assert {:ok, %{"operation_id" => nil, "operation_ids" => []}} =
             Foresight.retain_files(ctx, %{
               "files" => [
                 %{
                   "path" => upload_path,
                   "filename" => "contract.pdf",
                   "content_type" => "application/pdf",
                   "document_id" => "doc-file-1",
                   "metadata" => %{"source_kind" => "upload"}
                 }
               ],
               "request" => %{
                 "async" => false,
                 "context" => "kb",
                 "type" => "document",
                 "tags" => ["policy"],
                 "metadata" => %{"batch" => "tier2"}
               }
             })

    assert {:ok, %{"items" => [document | _], "total" => 1}} = Foresight.list_documents(ctx, %{})
    assert document["id"] == "doc-file-1"
    assert document["memory_unit_count"] == 1

    assert {:ok, %{"results" => [result | _], "chunks" => chunks}} =
             Foresight.recall(ctx, %{
               "query" => "contract",
               "include" => %{"chunks" => true}
             })

    assert result["document_id"] == "doc-file-1"
    assert is_binary(result["chunk_id"])
    assert Map.has_key?(chunks, result["chunk_id"])

    assert {:ok, %{rows: [[1, "doc-file-1", "contract.pdf", "application/pdf"]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT COUNT(*), d.external_id, d.file_original_name, d.file_content_type
               FROM documents AS d
               WHERE d.bank_id = $1
               GROUP BY d.external_id, d.file_original_name, d.file_content_type
               """,
               ["file-bank"]
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT COUNT(*)
               FROM file_storage AS fs
               WHERE fs.storage_key IN (
                 SELECT d.file_storage_key
                 FROM documents AS d
                 WHERE d.bank_id = $1 AND d.external_id = $2
               )
               """,
               ["file-bank", "doc-file-1"]
             )
  end

  test "text-body documents retain synchronously through Backend.Store" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_file_ingestion = Application.get_env(:foresight, :file_ingestion)

    on_exit(fn ->
      for {key, original} <- [
            backend: original_backend,
            engine: original_engine,
            file_ingestion: original_file_ingestion
          ] do
        if original,
          do: Application.put_env(:foresight, key, original),
          else: Application.delete_env(:foresight, key)
      end
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

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

    # Docling stays configured: text bodies must bypass it.
    Application.put_env(:foresight, :file_ingestion,
      enabled: true,
      converter: FakeDoclingConverter,
      converter_opts: []
    )

    sync_ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "text-sync-bank"}

    assert {:ok, _} =
             Foresight.retain_files(sync_ctx, %{
               "files" => [%{"text" => "Migrated document body", "document_id" => "src-doc-1"}],
               "request" => %{"async" => false, "metadata" => %{"batch" => "migration"}}
             })

    # Present the moment the call returns — no queue drain between.
    assert {:ok, %{"items" => [%{"id" => "src-doc-1"}], "total" => 1}} =
             Foresight.list_documents(sync_ctx, %{})

    # A text body carries no file bytes, so no file_storage row is attached.
    assert {:ok, %{rows: [[1, nil]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT COUNT(*), MAX(file_storage_key) FROM documents WHERE bank_id = $1",
               ["text-sync-bank"]
             )

    # Re-retaining a source id upserts the DOCUMENT but, by default, appends a second
    # set of memory units (Hindsight's default). update_mode "replace" is the opt-in
    # that deletes the prior set first.
    memory_count = fn ctx ->
      {:ok, %{rows: [[n]]}} =
        SQL.query(Foresight.Repo, "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1", [
          ctx.bank
        ])

      n
    end

    assert memory_count.(sync_ctx) == 1

    assert {:ok, _} =
             Foresight.retain_files(sync_ctx, %{
               "files" => [%{"text" => "Migrated document body", "document_id" => "src-doc-1"}],
               "request" => %{"async" => false}
             })

    assert {:ok, %{"total" => 1}} = Foresight.list_documents(sync_ctx, %{})
    assert memory_count.(sync_ctx) == 2

    assert {:ok, _} =
             Foresight.retain_files(sync_ctx, %{
               "files" => [%{"text" => "Migrated document body", "document_id" => "src-doc-1"}],
               "request" => %{"async" => false, "update_mode" => "replace"}
             })

    assert {:ok, %{"total" => 1}} = Foresight.list_documents(sync_ctx, %{})
    assert memory_count.(sync_ctx) == 1

    # Atom-keyed request options are NOT read: async stays at its default (true), so
    # nothing is written inline. Pins the string/atom pitfall for consumers.
    atom_ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "text-atom-bank"}

    assert {:ok, _} =
             Foresight.retain_files(atom_ctx, %{
               "files" => [%{"text" => "Migrated document body", "document_id" => "src-doc-2"}],
               "request" => %{async: false}
             })

    assert {:ok, %{"total" => 0}} = Foresight.list_documents(atom_ctx, %{})
  end

  test "update_mode replace releases sibling units for reconsolidation" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      for {key, original} <- [backend: original_backend, engine: original_engine] do
        if original,
          do: Application.put_env(:foresight, key, original),
          else: Application.delete_env(:foresight, key)
      end
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

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

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "replace-recon-bank"}

    for {id, body} <- [{"doc-a", "Alpha record content"}, {"doc-b", "Beta record content"}] do
      assert {:ok, _} =
               Foresight.retain_files(ctx, %{
                 "files" => [%{"text" => body, "document_id" => id}],
                 "request" => %{"async" => false}
               })
    end

    # Both source units are consolidated into ONE observation drawing on both documents.
    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               "UPDATE memory_units SET consolidated_at = now() WHERE bank_id = $1",
               [ctx.bank]
             )

    assert {:ok, %{num_rows: 1}} =
             SQL.query(
               Foresight.Repo,
               """
               INSERT INTO memory_units (context, metadata, tags, content, bank_id, fact_type,
                 embedding_384, embedded_by, embedded_dim, proof_count, source_memory_ids,
                 mentioned_at, observation_scopes, inserted_at, updated_at, id)
               SELECT context, metadata, tags, 'combined observation', bank_id, 'observation',
                 embedding_384, embedded_by, embedded_dim, 1,
                 ARRAY(SELECT id FROM memory_units WHERE bank_id = $1),
                 mentioned_at, observation_scopes, inserted_at, updated_at, gen_random_uuid()
               FROM memory_units WHERE bank_id = $1 LIMIT 1
               """,
               [ctx.bank]
             )

    # Replace document A only.
    assert {:ok, _} =
             Foresight.retain_files(ctx, %{
               "files" => [%{"text" => "Alpha record content", "document_id" => "doc-a"}],
               "request" => %{"async" => false, "update_mode" => "replace"}
             })

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT content, fact_type::text, consolidated_at IS NULL
               FROM memory_units WHERE bank_id = $1 ORDER BY content
               """,
               [ctx.bank]
             )

    # The observation is gone, and document B's unit — which survived — is released
    # so consolidation can form a fresh observation from it.
    assert [["Alpha record content", _, true], ["Beta record content", _, true]] = rows
  end

  test "recall trace works against persisted UUID-backed rows" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

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

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "trace-bank"}

    assert {:ok,
            %{
              "success" => true,
              "items_count" => 2,
              "trace" => %{"timings_ms" => retain_timings_ms}
            }} =
             Foresight.retain(ctx, %{
               "items" => [
                 %{
                   "content" => "Athens policy baseline for trace recall",
                   "context" => "kb",
                   "type" => "note",
                   "document_id" => "trace-doc-1",
                   "tags" => ["trace", "alpha"]
                 },
                 %{
                   "content" => "Policy follow-up cites the baseline",
                   "context" => "kb",
                   "type" => "note",
                   "document_id" => "trace-doc-2",
                   "tags" => ["trace", "beta"]
                 }
               ],
               "async" => false,
               "trace" => true
             })

    assert is_integer(retain_timings_ms["extraction_ms"])
    assert is_integer(retain_timings_ms["runtime_config_ms"])
    assert is_integer(retain_timings_ms["embedding_profile_ms"])
    assert is_integer(retain_timings_ms["prepare_memory_units_ms"])
    assert is_integer(retain_timings_ms["transaction_ms"])
    assert is_integer(retain_timings_ms["total_ms"])

    assert {:ok,
            %{
              "results" => [_ | _],
              "trace" => %{
                "summary" => %{},
                "timings_ms" => recall_timings_ms,
                "displacement" => %{"final_trimmed_out" => final_trimmed_out}
              },
              "chunks" => chunks,
              "source_facts" => source_facts
            }} =
             Foresight.recall(ctx, %{
               "query" => "policy baseline",
               "trace" => true,
               "include" => %{"chunks" => %{}, "source_facts" => %{}}
             })

    assert is_integer(final_trimmed_out)
    assert is_integer(recall_timings_ms["runtime_config_ms"])
    assert is_integer(recall_timings_ms["normalize_payload_ms"])
    assert is_integer(recall_timings_ms["embedding_profile_ms"])
    assert is_integer(recall_timings_ms["query_embedding_ms"])
    assert is_integer(recall_timings_ms["ranked_recall_ms"])
    assert is_integer(recall_timings_ms["rerank_candidates_ms"])
    assert is_integer(recall_timings_ms["rerank_ms"])
    assert is_integer(recall_timings_ms["boost_ms"])
    assert is_integer(recall_timings_ms["trim_ms"])
    assert is_integer(recall_timings_ms["entity_lookup_ms"])
    assert is_integer(recall_timings_ms["results_ms"])
    assert is_integer(recall_timings_ms["chunks_ms"])
    assert is_integer(recall_timings_ms["source_facts_ms"])
    assert is_integer(recall_timings_ms["total_ms"])
    assert is_map(chunks)
    assert is_map(source_facts)
  end

  test "entity_graph and memory_graph shape data from persisted rows" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "graph-bank"}

    assert {:ok, %{"success" => true, "items_count" => 2}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "Alice works at Google in Athens",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["graph"]
                 },
                 %{
                   "content" => "Bob met Alice at Google Athens office",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["graph"]
                 }
               ]
             })

    assert {:ok, entity_graph} = Foresight.entity_graph(ctx, %{"limit" => 10, "min_count" => 1})
    assert entity_graph["total_entities"] >= 2
    assert entity_graph["total_edges"] >= 1
    assert [%{"data" => entity_edge} | _] = entity_graph["edges"]
    assert entity_edge["linkType"] == "cooccurrence"
    assert is_binary(entity_edge["lastCooccurred"])

    assert {:ok, memory_graph} = Foresight.memory_graph(ctx, %{"limit" => 10, "type" => "world"})
    assert memory_graph["total_units"] == 2
    assert length(memory_graph["nodes"]) == 2
    assert length(memory_graph["table_rows"]) == 2

    assert Enum.any?(memory_graph["edges"], fn %{"data" => edge} ->
             edge["linkType"] == "semantic"
           end)

    assert Enum.any?(memory_graph["table_rows"], fn row ->
             row["entities"] != "" and row["fact_type"] == "world"
           end)
  end

  test "bank config overrides persist and reset through the real store" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{tenant_id: "tenant-a", mode: :mode_a, bank: "config-bank"}

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "config-bank", %{"name" => "Config Bank"})

    assert {:ok, config_response} =
             Foresight.update_bank_config(
               ctx,
               "config-bank",
               %{
                 "HINDSIGHT_API_RECALL_MAX_TOKENS" => 1024,
                 "HINDSIGHT_API_RECALL_RERANK_WINDOW" => 80,
                 "reflect_mission" => "tenant-specific"
               },
               config: %{
                 bank_config: %{
                   tenants: %{"tenant-a" => %{"reflect_mission" => "tenant fallback"}}
                 }
               }
             )

    assert config_response["config"]["recall_max_tokens"] == 1024
    assert config_response["config"]["recall_rerank_window"] == 80
    assert config_response["config"]["reflect_mission"] == "tenant-specific"

    assert config_response["overrides"] == %{
             "recall_max_tokens" => 1024,
             "recall_rerank_window" => 80,
             "reflect_mission" => "tenant-specific"
           }

    assert {:ok, reset_response} =
             Foresight.reset_bank_config(ctx, "config-bank",
               config: %{
                 bank_config: %{
                   tenants: %{"tenant-a" => %{"reflect_mission" => "tenant fallback"}}
                 }
               }
             )

    assert reset_response["config"]["recall_max_tokens"] == 2048
    assert is_nil(reset_response["config"]["recall_rerank_window"])
    assert reset_response["config"]["reflect_mission"] == "tenant fallback"
    assert reset_response["overrides"] == %{}

    assert {:ok, %{rows: [[%{}]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT config_overrides FROM banks WHERE id = $1",
               ["config-bank"]
             )
  end

  test "embedding profile change enqueues and completes a real backfill operation" do
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{tenant_id: "tenant-a", mode: :mode_a, bank: "embedding-config-bank"}

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "embedding-config-bank", %{"name" => "Embedding Config Bank"})

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [%{"content" => "needs live backfill", "context" => "chat"}]
             })

    assert {:ok, _config} =
             Foresight.update_bank_config(ctx, "embedding-config-bank", %{
               "embed_model" => "custom/model"
             })

    assert {:ok,
            %{"operations" => [%{"id" => operation_id, "task_type" => "embedding_backfill"}]}} =
             Foresight.list_operations(ctx)

    Foresight.TestSupport.FakeAsyncQueue.drain!()

    assert {:ok,
            %{
              "operation_id" => ^operation_id,
              "status" => "completed",
              "result" => %{
                "bank_id" => "embedding-config-bank",
                "updated_count" => 1,
                "target_profile" => %{"model_id" => "custom/model", "embedding_dim" => 384}
              }
            }} = Foresight.get_operation(ctx, operation_id)

    assert {:ok, %{rows: [["custom/model", 384]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT embedded_by, embedded_dim FROM memory_units WHERE bank_id = $1",
               ["embedding-config-bank"]
             )
  end

  test "banks with 384 and 1024 embedding profiles retain and recall side by side" do
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx_384 = %Context{tenant_id: "tenant-a", mode: :mode_a, bank: "bank-384"}
    ctx_1024 = %Context{tenant_id: "tenant-a", mode: :mode_a, bank: "bank-1024"}

    assert {:ok, _bank} = Foresight.put_bank(ctx_384, "bank-384", %{"name" => "Bank 384"})
    assert {:ok, _bank} = Foresight.put_bank(ctx_1024, "bank-1024", %{"name" => "Bank 1024"})

    assert {:ok, _config} =
             Foresight.update_bank_config(ctx_1024, "bank-1024", %{
               "embed_model" => "custom/1024",
               "embedding_dim" => 1024
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_384, %{
               "async" => false,
               "items" => [%{"content" => "alpha 384 memory", "context" => "chat"}]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_1024, %{
               "async" => false,
               "items" => [%{"content" => "beta 1024 memory", "context" => "chat"}]
             })

    assert {:ok,
            %{
              "results" => [%{"text" => "alpha 384 memory"}]
            }} = Foresight.recall(ctx_384, %{"query" => "alpha", "max_tokens" => 20})

    assert {:ok,
            %{
              "results" => [%{"text" => "beta 1024 memory"}]
            }} = Foresight.recall(ctx_1024, %{"query" => "beta", "max_tokens" => 20})

    assert {:ok, %{rows: rows}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT bank_id, embedded_dim, embedded_by, embedding_384 IS NOT NULL, embedding_1024 IS NOT NULL
               FROM memory_units
               WHERE bank_id IN ($1, $2)
               ORDER BY bank_id
               """,
               ["bank-384", "bank-1024"]
             )

    assert rows == [
             ["bank-1024", 1024, "custom/1024", false, true],
             ["bank-384", 384, "BAAI/bge-small-en-v1.5", true, false]
           ]
  end

  test "bank template import/export round-trips config, directives, and mental model seeds" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    source_ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "template-source"}
    target_ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "template-target"}

    manifest = %{
      "version" => "1",
      "bank" => %{
        "reflect_mission" => "Support agent memory",
        "recall_max_tokens" => 1024,
        "disposition_empathy" => 5
      },
      "directives" => [
        %{
          "name" => "Always be empathetic",
          "content" => "Lead with empathy and clarity.",
          "priority" => 10,
          "tags" => ["support"]
        }
      ],
      "mental_models" => [
        %{
          "id" => "mental-model:sentiment-overview",
          "name" => "Sentiment Overview",
          "source_query" => "Summarize sentiment trend",
          "tags" => ["support"],
          "max_tokens" => 1536,
          "trigger" => %{"refresh_after_consolidation" => true}
        }
      ]
    }

    assert {:ok, import_response} =
             Foresight.import_bank_template(source_ctx, "template-source", manifest)

    assert import_response["config_applied"] == true
    assert import_response["directives_created"] == ["Always be empathetic"]
    assert import_response["mental_models_created"] == ["mental-model:sentiment-overview"]

    assert {:ok, exported_source} =
             Foresight.export_bank_template(source_ctx, "template-source")

    assert exported_source["version"] == "1"
    assert exported_source["bank"]["reflect_mission"] == "Support agent memory"
    assert exported_source["bank"]["recall_max_tokens"] == 1024
    assert exported_source["bank"]["disposition_empathy"] == 5
    assert hd(exported_source["directives"])["name"] == "Always be empathetic"
    assert hd(exported_source["mental_models"])["source_query"] == "Summarize sentiment trend"

    assert {:ok, dry_run_response} =
             Foresight.import_bank_template(
               target_ctx,
               "template-target",
               Map.put(exported_source, "dry_run", true)
             )

    assert dry_run_response["dry_run"] == true

    assert {:error, %Foresight.Error{reason: :not_found}} =
             Foresight.export_bank_template(target_ctx, "template-target")

    assert {:ok, _real_import_response} =
             Foresight.import_bank_template(target_ctx, "template-target", exported_source)

    assert {:ok, exported_target} =
             Foresight.export_bank_template(target_ctx, "template-target")

    assert exported_target["bank"] == exported_source["bank"]
    assert exported_target["directives"] == exported_source["directives"]
    assert exported_target["mental_models"] == exported_source["mental_models"]

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT COUNT(*) FROM directives WHERE bank_id = $1 AND name = $2",
               ["template-target", "Always be empathetic"]
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT COUNT(*) FROM documents WHERE bank_id = $1 AND external_id = $2",
               ["template-target", "mental-model:sentiment-overview"]
             )
  end

  test "recall consumes persisted runtime budget and max token config" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "runtime-recall-bank"}

    assert {:ok, %{"success" => true, "items_count" => 6}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" =>
                 Enum.map(1..6, fn idx ->
                   %{
                     "content" => "alpha runtime memory #{idx}",
                     "context" => "chat",
                     "type" => "world",
                     "tags" => ["runtime"]
                   }
                 end)
             })

    assert {:ok, _config} =
             Foresight.update_bank_config(ctx, "runtime-recall-bank", %{
               "recall_budget_function" => "adaptive",
               "recall_budget_adaptive_low" => 0.01,
               "recall_budget_min" => 1,
               "recall_budget_max" => 10,
               "recall_max_tokens" => 200
             })

    assert {:ok, %{"results" => results}} =
             Foresight.recall(ctx, %{
               "query" => "alpha runtime",
               "budget" => "low"
             })

    assert length(results) == 2
  end

  test "reflect consumes persisted mission, disposition, and role llm config" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: CaptureReflectLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "runtime-reflect-bank"}

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "alpha runtime reflect note",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "runtime-reflect-bank", %{
               "name" => "Runtime Reflect Bank",
               "mission" => "bank mission",
               "disposition" => %{"skepticism" => 1, "empathy" => 2}
             })

    assert {:ok, _config} =
             Foresight.update_bank_config(ctx, "runtime-reflect-bank", %{
               "reflect_mission" => "runtime reflect mission",
               "disposition_skepticism" => 9,
               "llm_reflect_provider" => "openai",
               "llm_reflect_model" => "gpt-reflect-test",
               "llm_reflect_base_url" => "http://llm.local",
               "llm_reflect_api_key" => "sk-runtime-reflect"
             })

    assert {:ok, %{"text" => text}} =
             Foresight.reflect(ctx, %{"query" => "alpha"})

    assert text =~ "runtime reflect mission"
    assert text =~ "skepticism=9"
    assert text =~ "empathy=2"

    calls = CapturedReflectCalls.entries()
    assert calls != []

    assert Enum.any?(calls, fn call ->
             call.response_module == Foresight.Prompts.ReflectPlanResponse and
               get_in(call.prompt, [:bank, :mission]) == "runtime reflect mission"
           end)

    assert Enum.all?(calls, fn call ->
             call.opts[:provider] == "openai" and
               call.opts[:provider_opts][:model] == "gpt-reflect-test" and
               call.opts[:provider_opts][:base_url] == "http://llm.local" and
               call.opts[:provider_opts][:api_key] == "sk-runtime-reflect"
           end)
  end

  test "reflect can scope observations by tags on postgres" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{tenant_id: "tenant-reflect-tags", mode: :mode_a, bank: "reflect-tags-bank"}

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "alpha tagged memory",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.consolidate(ctx, %{"tag_scopes" => [%{"tags" => ["alpha"]}]})

    assert {:ok, %{"text" => _text}} =
             Foresight.reflect(ctx, %{"query" => "alpha", "tags" => ["alpha"]})
  end

  test "mode_c reflect releases the checked-out connection before llm work" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
    end)

    Application.put_env(
      :foresight,
      SingleConnRepo,
      Keyword.merge(repo_config,
        pool_size: 5,
        timeout: 75
      )
    )

    start_supervised!(SingleConnRepo)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: SingleConnRepo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: SlowReflectLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    prefix = "tenant_mode_c_reflect_scope"
    role_name = "tenant_mode_c_reflect_scope_app"

    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_reflect_scope_app"|, [])

    on_exit(fn ->
      _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_reflect_scope_app"|, [])
    end)

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo)
    SQL.query!(SingleConnRepo, ~s|CREATE ROLE "tenant_mode_c_reflect_scope_app" NOINHERIT|, [])

    SQL.query!(
      SingleConnRepo,
      ~s|GRANT USAGE ON SCHEMA "tenant_mode_c_reflect_scope" TO "tenant_mode_c_reflect_scope_app"|,
      []
    )

    SQL.query!(
      SingleConnRepo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "tenant_mode_c_reflect_scope" TO "tenant_mode_c_reflect_scope_app"|,
      []
    )

    SQL.query!(
      SingleConnRepo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "tenant_mode_c_reflect_scope" TO "tenant_mode_c_reflect_scope_app"|,
      []
    )

    ctx = %Context{
      tenant_id: "tenant-mode-c-reflect-scope",
      mode: :mode_c,
      bank: "shared-bank",
      prefix: prefix,
      role_name: role_name
    }

    assert {:ok, count} = Foresight.Tokenizers.Cl100kBase.count("warm tokenizer path")
    assert count > 0

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "mode c reflect scope memory",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, %{"text" => text}} = Foresight.reflect(ctx, %{"query" => "alpha"})
    assert text =~ "mode c reflect scope memory"
  end

  test "reflect returns a typed error when the llm task exits" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: ExitingReflectLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    ctx = %Context{tenant_id: "tenant-reflect-exit", mode: :mode_a, bank: "reflect-exit-bank"}

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "reflect exit memory", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:error, %Foresight.Error{reason: :service_unavailable, detail: %{message: message}}} =
             Foresight.reflect(ctx, %{"query" => "reflect exit"})

    assert message =~ "simulated_llm_exit"
  end

  test "mode_b prefixed contexts isolate the same bank id across tenant schemas" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    prefix_a = "tenant_mode_b_a"
    prefix_b = "tenant_mode_b_b"

    assert {:ok, _} = SchemaProvisioner.provision(prefix_a, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(prefix_b, repo: Foresight.Repo)

    ctx_a = %Context{tenant_id: "tenant-a", mode: :mode_b, bank: "shared-bank", prefix: prefix_a}
    ctx_b = %Context{tenant_id: "tenant-b", mode: :mode_b, bank: "shared-bank", prefix: prefix_b}

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_a, %{
               "async" => false,
               "items" => [
                 %{"content" => "alpha tenant memory", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_b, %{
               "async" => false,
               "items" => [
                 %{"content" => "beta tenant memory", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, %{"results" => [%{"text" => "alpha tenant memory"}]}} =
             Foresight.recall(ctx_a, %{"query" => "alpha tenant"})

    assert {:ok, %{"results" => [%{"text" => "beta tenant memory"}]}} =
             Foresight.recall(ctx_b, %{"query" => "beta tenant"})

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(Foresight.Repo, "SELECT count(*) FROM #{prefix_a}.banks", [])

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(Foresight.Repo, "SELECT count(*) FROM #{prefix_b}.banks", [])

    assert {:ok, %{rows: [["alpha tenant memory"]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT content FROM #{prefix_a}.memory_units WHERE bank_id = 'shared-bank'",
               []
             )

    assert {:ok, %{rows: [["beta tenant memory"]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT content FROM #{prefix_b}.memory_units WHERE bank_id = 'shared-bank'",
               []
             )
  end

  test "mode_c contexts run storage paths under the tenant role" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    prefix = "tenant_mode_c_store"
    role_name = "tenant_mode_c_store_app"

    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_store_app"|, [])

    on_exit(fn ->
      _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_store_app"|, [])
    end)

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo)
    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "tenant_mode_c_store_app" NOINHERIT|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE ON SCHEMA "tenant_mode_c_store" TO "tenant_mode_c_store_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "tenant_mode_c_store" TO "tenant_mode_c_store_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "tenant_mode_c_store" TO "tenant_mode_c_store_app"|,
      []
    )

    ctx = %Context{
      tenant_id: "tenant-c",
      mode: :mode_c,
      bank: "shared-bank",
      prefix: prefix,
      role_name: role_name
    }

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "gamma tenant memory", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok,
            %{
              "results" => [%{"text" => "gamma tenant memory"}],
              "trace" => %{"strategies" => strategies}
            }} =
             Foresight.recall(ctx, %{"query" => "gamma tenant", "trace" => true})

    assert Map.keys(strategies) |> Enum.sort() == ["graph", "keyword", "semantic", "temporal"]

    assert Enum.all?(strategies, fn {_name, trace} ->
             trace["db_role"] == role_name
           end)

    assert {:ok, %{rows: [["postgres"]]}} = SQL.query(Foresight.Repo, "SELECT current_role", [])

    assert {:ok, %{rows: [["gamma tenant memory"]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT content FROM #{prefix}.memory_units WHERE bank_id = 'shared-bank'",
               []
             )
  end

  test "mode_c optional rls blocks mis-scoped queries when enabled" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_tenancy = Application.get_env(:foresight, :tenancy)

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
      restore_env(:tenancy, original_tenancy)
    end)

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

    Application.put_env(:foresight, :tenancy, rls_enabled: true)

    prefix = "tenant_mode_c_rls_on"
    role_name = "tenant_mode_c_rls_on_app"

    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo, rls_enabled: true)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_rls_on_app"|, [])

    on_exit(fn ->
      _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo, rls_enabled: true)
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_rls_on_app"|, [])
    end)

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo, rls_enabled: true)
    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "tenant_mode_c_rls_on_app" NOINHERIT|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE ON SCHEMA "tenant_mode_c_rls_on" TO "tenant_mode_c_rls_on_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "tenant_mode_c_rls_on" TO "tenant_mode_c_rls_on_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "tenant_mode_c_rls_on" TO "tenant_mode_c_rls_on_app"|,
      []
    )

    ctx = %Context{
      tenant_id: "tenant-rls-on",
      mode: :mode_c,
      bank: "shared-bank",
      prefix: prefix,
      role_name: role_name
    }

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "delta tenant memory", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, %{"results" => [%{"text" => "delta tenant memory"}]}} =
             Foresight.recall(ctx, %{"query" => "delta tenant"})

    assert {:ok, %{rows: [[0]]}} =
             Foresight.Repo.transaction(fn ->
               SQL.query!(Foresight.Repo, ~s|SET LOCAL ROLE "tenant_mode_c_rls_on_app"|, [])

               SQL.query!(
                 Foresight.Repo,
                 "SELECT set_config('foresight.tenant_prefix', 'tenant_elsewhere', true)",
                 []
               )

               SQL.query!(
                 Foresight.Repo,
                 "SELECT count(*) FROM #{prefix}.memory_units WHERE bank_id = 'shared-bank'",
                 []
               )
             end)
  end

  test "mode_c behavior is unchanged when optional rls is disabled" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_tenancy = Application.get_env(:foresight, :tenancy)

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
      restore_env(:tenancy, original_tenancy)
    end)

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

    Application.put_env(:foresight, :tenancy, rls_enabled: false)

    prefix = "tenant_mode_c_rls_off"
    role_name = "tenant_mode_c_rls_off_app"

    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo, rls_enabled: false)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_rls_off_app"|, [])

    on_exit(fn ->
      _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo, rls_enabled: false)
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_rls_off_app"|, [])
    end)

    assert {:ok, _} =
             SchemaProvisioner.provision(prefix, repo: Foresight.Repo, rls_enabled: false)

    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "tenant_mode_c_rls_off_app" NOINHERIT|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE ON SCHEMA "tenant_mode_c_rls_off" TO "tenant_mode_c_rls_off_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "tenant_mode_c_rls_off" TO "tenant_mode_c_rls_off_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "tenant_mode_c_rls_off" TO "tenant_mode_c_rls_off_app"|,
      []
    )

    ctx = %Context{
      tenant_id: "tenant-rls-off",
      mode: :mode_c,
      bank: "shared-bank",
      prefix: prefix,
      role_name: role_name
    }

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "epsilon tenant memory", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, %{"results" => [%{"text" => "epsilon tenant memory"}]}} =
             Foresight.recall(ctx, %{"query" => "epsilon tenant"})

    assert {:ok, %{rows: [[1]]}} =
             Foresight.Repo.transaction(fn ->
               SQL.query!(Foresight.Repo, ~s|SET LOCAL ROLE "tenant_mode_c_rls_off_app"|, [])

               SQL.query!(
                 Foresight.Repo,
                 "SELECT set_config('foresight.tenant_prefix', 'tenant_elsewhere', true)",
                 []
               )

               SQL.query!(
                 Foresight.Repo,
                 "SELECT count(*) FROM #{prefix}.memory_units WHERE bank_id = 'shared-bank'",
                 []
               )
             end)
  end

  test "mode_c webhook deliveries execute under the tenant role" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_webhook_delivery = Application.get_env(:foresight, :webhook_delivery)

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
      restore_env(:webhook_delivery, original_webhook_delivery)
    end)

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

    Application.put_env(:foresight, :webhook_delivery, http_client: RoleAwareWebhookHTTPClient)

    prefix = "tenant_mode_c_webhook"
    role_name = "tenant_mode_c_webhook_app"

    _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_webhook_app"|, [])

    on_exit(fn ->
      _ = SchemaProvisioner.drop(prefix, repo: Foresight.Repo)
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_mode_c_webhook_app"|, [])
    end)

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo)
    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "tenant_mode_c_webhook_app" NOINHERIT|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE ON SCHEMA "tenant_mode_c_webhook" TO "tenant_mode_c_webhook_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "tenant_mode_c_webhook" TO "tenant_mode_c_webhook_app"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "tenant_mode_c_webhook" TO "tenant_mode_c_webhook_app"|,
      []
    )

    ctx = %Context{
      tenant_id: "tenant-webhook-mode-c",
      mode: :mode_c,
      bank: "mode-c-hook-bank",
      prefix: prefix,
      role_name: role_name
    }

    assert {:ok, webhook} =
             Foresight.create_webhook(ctx, "mode-c-hook-bank", %{
               "url" => "https://example.test/mode-c-hook",
               "event_types" => ["consolidation.completed"],
               "enabled" => true
             })

    webhook_id = webhook["id"]

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "mode c webhook memory",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.consolidate(ctx, %{"tag_scopes" => [%{"tags" => ["alpha"]}]})

    assert %Job{} =
             job =
             Foresight.Repo.one(
               from(job in Job,
                 where: job.worker == ^"Foresight.Jobs.WebhookDeliveryWorker",
                 order_by: [desc: job.inserted_at],
                 limit: 1
               )
             )

    assert :ok =
             Foresight.Jobs.WebhookDeliveryWorker.perform(%{job | attempt: 1, max_attempts: 2})

    [call] = RoleAwareWebhookHTTPClient.calls()
    assert call.db_role == role_name
    assert call.url == "https://example.test/mode-c-hook"
    assert call.payload["event_type"] == "consolidation.completed"

    assert [%{"id" => ^webhook_id, "status" => "delivered"}] =
             Foresight.Repo.all(
               from(delivery in Delivery,
                 where: delivery.bank_id == ^"mode-c-hook-bank",
                 select: %{"id" => delivery.webhook_id, "status" => delivery.status}
               ),
               prefix: prefix
             )
  end

  test "write-path mutations append audit log rows with actor metadata" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{
      tenant_id: "tenant-audit",
      mode: :mode_a,
      bank: "audit-bank",
      role_name: "auditor"
    }

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "audit-bank", %{
               "name" => "Audit Bank",
               "mission" => "track changes"
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "alpha audit memory",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.consolidate(ctx, %{"tag_scopes" => [%{"tags" => ["alpha"]}]})

    assert {:ok, _bank} =
             Foresight.patch_bank(ctx, "audit-bank", %{"mission" => "patched mission"})

    assert {:ok, %{"deleted" => true}} =
             Foresight.clear_bank_memories(ctx, "audit-bank", %{})

    assert {:ok, %{"deleted" => true}} =
             Foresight.delete_bank(ctx, "audit-bank")

    rows =
      Foresight.Repo.all(
        from(audit_log in AuditLog,
          where: audit_log.bank_id == ^"audit-bank",
          order_by: [asc: audit_log.started_at]
        )
      )

    assert Enum.map(rows, & &1.action) == [
             "put_bank",
             "retain",
             "consolidate",
             "patch_bank",
             "clear_bank_memories",
             "delete_bank"
           ]

    assert Enum.all?(rows, fn row ->
             row.transport == "backend" and
               row.metadata["actor"] == "auditor" and
               row.metadata["tenant_id"] == "tenant-audit" and
               row.started_at != nil and
               row.ended_at != nil
           end)
  end

  test "consolidation webhooks enqueue durable deliveries and record failure then terminal status" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_webhook_delivery = Application.get_env(:foresight, :webhook_delivery)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end

      if original_webhook_delivery do
        Application.put_env(:foresight, :webhook_delivery, original_webhook_delivery)
      else
        Application.delete_env(:foresight, :webhook_delivery)
      end
    end)

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

    Application.put_env(:foresight, :webhook_delivery, http_client: FakeWebhookHTTPClient)

    FakeWebhookHTTPClient.put_responses([
      {:error, :econnrefused},
      {:error, :timeout}
    ])

    ctx = %Context{
      tenant_id: "tenant-hook",
      mode: :mode_a,
      bank: "hook-bank",
      role_name: "operator"
    }

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, "hook-bank", %{
               "name" => "Hook Bank",
               "mission" => "emit events"
             })

    {:ok, webhook} =
      %Webhook{}
      |> Webhook.changeset(%{
        bank_id: "hook-bank",
        url: "http://example.test/webhook",
        enabled: true,
        event_types: ["consolidation.completed"],
        http_config: %{
          "timeout_seconds" => 3,
          "headers" => %{"x-test-source" => "foresight"},
          "params" => %{"mode" => "integration"}
        }
      })
      |> Foresight.Repo.insert()

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "alpha webhook memory",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.consolidate(ctx, %{"tag_scopes" => [%{"tags" => ["alpha"]}]})

    assert [delivery] =
             Foresight.Repo.all(
               from(delivery in Delivery,
                 where: delivery.bank_id == ^"hook-bank",
                 order_by: [asc: delivery.inserted_at]
               )
             )

    assert delivery.webhook_id == webhook.id
    assert delivery.event_type == "consolidation.completed"
    assert delivery.status == "pending"

    assert %Job{} =
             job =
             Foresight.Repo.one(
               from(job in Job,
                 where: job.worker == ^"Foresight.Jobs.WebhookDeliveryWorker",
                 order_by: [desc: job.inserted_at],
                 limit: 1
               )
             )

    assert {:error, _error} =
             Foresight.Jobs.WebhookDeliveryWorker.perform(%{job | attempt: 1, max_attempts: 2})

    delivery = Foresight.Repo.get!(Delivery, delivery.id)
    assert delivery.status == "pending"
    assert delivery.attempts == 1
    assert delivery.last_error =~ "econnrefused"

    assert {:error, _error} =
             Foresight.Jobs.WebhookDeliveryWorker.perform(%{job | attempt: 2, max_attempts: 2})

    delivery = Foresight.Repo.get!(Delivery, delivery.id)
    assert delivery.status == "failed"
    assert delivery.attempts == 2
    assert delivery.last_error =~ "timeout"

    [call | _] = FakeWebhookHTTPClient.calls()
    assert call.url == "http://example.test/webhook?mode=integration"
    assert call.payload["event_type"] == "consolidation.completed"
    assert Keyword.get(call.opts, :timeout_ms) == 3_000
  end

  test "webhook admin surface persists CRUD and delivery inspection through the store" do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end

      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

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

    ctx = %Context{
      tenant_id: "tenant-webhook-admin",
      mode: :mode_a,
      bank: "admin-hook-bank",
      role_name: "operator"
    }

    assert {:ok, webhook} =
             Foresight.create_webhook(ctx, "admin-hook-bank", %{
               "url" => "https://example.test/admin-hook",
               "secret" => "top-secret",
               "event_types" => ["consolidation.completed"],
               "enabled" => true,
               "http_config" => %{
                 "method" => "POST",
                 "timeout_seconds" => 12,
                 "headers" => %{"x-source" => "foresight"},
                 "params" => %{"mode" => "admin"}
               }
             })

    assert webhook["bank_id"] == "admin-hook-bank"
    assert webhook["secret"] == nil
    assert webhook["http_config"]["timeout_seconds"] == 12
    assert Foresight.Repo.get!(Bank, "admin-hook-bank")

    assert {:ok, [listed]} = Foresight.list_webhooks(ctx, "admin-hook-bank")
    assert listed["id"] == webhook["id"]

    assert {:ok, updated} =
             Foresight.update_webhook(ctx, "admin-hook-bank", webhook["id"], %{
               "enabled" => false,
               "http_config" => %{"method" => "GET", "timeout_seconds" => 7}
             })

    assert updated["enabled"] == false
    assert updated["http_config"]["method"] == "GET"
    assert updated["secret"] == nil

    assert {:ok, _delivery} =
             %Delivery{}
             |> Delivery.changeset(%{
               bank_id: "admin-hook-bank",
               webhook_id: webhook["id"],
               event_type: "consolidation.completed",
               url: "https://example.test/admin-hook",
               status: "failed",
               attempts: 2,
               last_error: "timeout",
               last_attempt_at: DateTime.utc_now()
             })
             |> Foresight.Repo.insert()

    assert {:ok, deliveries} =
             Foresight.list_webhook_deliveries(ctx, "admin-hook-bank", webhook["id"], %{
               "limit" => 10
             })

    assert [%{"webhook_id" => webhook_id, "status" => "failed", "last_error" => "timeout"}] =
             deliveries["items"]

    assert webhook_id == webhook["id"]
    assert deliveries["next_cursor"] == nil

    assert {:ok, %{"success" => true}} =
             Foresight.delete_webhook(ctx, "admin-hook-bank", webhook["id"])

    assert {:ok, []} = Foresight.list_webhooks(ctx, "admin-hook-bank")
  end

  describe "retain replace and document upsert" do
    setup do
      configure_store_engine!()
      :ok
    end

    test "replace retracts only the replaced document's entity mentions" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "replace-entities-bank"}

      retain = fn document_id, content, entities, update_mode ->
        item = %{
          "content" => content,
          "context" => "chat",
          "document_id" => document_id,
          "entities" => entities
        }

        item = if update_mode, do: Map.put(item, "update_mode", update_mode), else: item
        assert {:ok, _} = Foresight.retain(ctx, %{"items" => [item]})
      end

      # Entities arrive on the items the way fact extraction threads them in, so this
      # pins what the whole-bank rebuild used to destroy: LLM-derived entities that no
      # regex would re-derive from the text.
      retain.("doc-a", "alpha record", ["Alpha Corp", "Shared Thing"], nil)
      retain.("doc-b", "beta record", ["Beta Ltd", "Shared Thing"], nil)

      assert entity_mentions(ctx) == [["Alpha Corp", 1], ["Beta Ltd", 1], ["Shared Thing", 2]]

      assert link_weights(ctx) == [
               {["Alpha Corp", "Shared Thing"], 1},
               {["Beta Ltd", "Shared Thing"], 1}
             ]

      retain.("doc-a", "alpha record v2", ["Gamma Inc"], "replace")

      # Alpha Corp had no other mention and is pruned; Shared Thing lost doc-a's mention
      # but keeps doc-b's; Beta Ltd is untouched; Gamma Inc is new. The exhausted
      # Alpha-Shared link is gone and the Beta-Shared link keeps its weight.
      assert entity_mentions(ctx) == [["Beta Ltd", 1], ["Gamma Inc", 1], ["Shared Thing", 1]]
      assert link_weights(ctx) == [{["Beta Ltd", "Shared Thing"], 1}]

      assert {:ok, %{rows: [[3]]}} =
               SQL.query(
                 Foresight.Repo,
                 """
                 SELECT COUNT(*) FROM memory_unit_entities mue
                 JOIN memory_units mu ON mu.id = mue.memory_unit_id
                 WHERE mu.bank_id = $1
                 """,
                 [ctx.bank]
               )
    end

    test "concurrent replaces of one document leave exactly one set of units" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "replace-race-bank"}

      payload = fn n ->
        %{
          "items" => [
            %{
              "content" => "race body #{n}",
              "context" => "chat",
              "document_id" => "doc-race",
              "update_mode" => "replace"
            }
          ]
        }
      end

      assert {:ok, _} = Foresight.retain(ctx, payload.(0))

      results =
        1..6
        |> Enum.map(fn n -> Task.async(fn -> Foresight.retain(ctx, payload.(n)) end) end)
        |> Task.await_many(60_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      assert {:ok, %{rows: [[1]]}} =
               SQL.query(
                 Foresight.Repo,
                 "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1 AND document_ref = $2",
                 [ctx.bank, "doc-race"]
               )

      assert {:ok, %{"total" => 1}} = Foresight.list_documents(ctx, %{})
    end

    test "concurrent first retains of a new document id all succeed" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "document-race-bank"}

      results =
        1..4
        |> Enum.map(fn n ->
          Task.async(fn ->
            Foresight.retain(ctx, %{
              "items" => [
                %{"content" => "first body #{n}", "context" => "chat", "document_id" => "doc-new"}
              ]
            })
          end)
        end)
        |> Task.await_many(60_000)

      # The former read-then-write upsert raised Ecto.ConstraintError for every loser.
      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, %{"total" => 1}} = Foresight.list_documents(ctx, %{})

      assert {:ok, %{rows: [[4]]}} =
               SQL.query(
                 Foresight.Repo,
                 "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1 AND document_ref = $2",
                 [ctx.bank, "doc-new"]
               )
    end

    test "recall exposes score, applies min_score, and validates it" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "min-score-bank"}

      assert {:ok, %{"extraction" => %{"enabled" => false}}} =
               Foresight.retain(ctx, %{
                 "items" => [
                   %{"content" => "project alpha exact", "context" => "chat"},
                   %{"content" => "project alpha", "context" => "chat"}
                 ]
               })

      assert {:ok, %{"results" => results}} =
               Foresight.recall(ctx, %{"query" => "project alpha"})

      assert results != []
      assert Enum.all?(results, &is_number(&1["score"]))

      assert {:ok, %{"results" => []}} =
               Foresight.recall(ctx, %{"query" => "project alpha", "min_score" => 2.0})

      assert {:error, %Foresight.Error{reason: :invalid_request}} =
               Foresight.recall(ctx, %{"query" => "project alpha", "min_score" => "high"})

      assert {:error, %Foresight.Error{reason: :invalid_request}} =
               Foresight.recall(ctx, %{"query" => "project alpha", "limit" => 1})
    end

    test "concurrent delete_document and replace of one document do not deadlock" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "delete-replace-race-bank"}

      replace = fn n ->
        Foresight.retain(ctx, %{
          "items" => [
            %{
              "content" => "race body #{n}",
              "context" => "chat",
              "document_id" => "doc-dr",
              "update_mode" => "replace"
            }
          ]
        })
      end

      assert {:ok, _} = replace.(0)

      # Replace locks the document row before its units; delete used to lock the units
      # before the row. Postgres aborted one side with deadlock_detected, which
      # surfaces here as a crashed task.
      results =
        [
          fn -> replace.(1) end,
          fn -> Foresight.delete_document(ctx, ctx.bank, "doc-dr") end,
          fn -> replace.(2) end,
          fn -> Foresight.delete_document(ctx, ctx.bank, "doc-dr") end,
          fn -> replace.(3) end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(60_000)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, %Foresight.Error{reason: :not_found}} -> true
               _ -> false
             end)

      {:ok, %{rows: [[units]]}} =
        SQL.query(
          Foresight.Repo,
          "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1 AND document_ref = $2",
          [ctx.bank, "doc-dr"]
        )

      {:ok, %{"total" => documents}} = Foresight.list_documents(ctx, %{})

      # The last writer was either a replace (one document, one unit) or a delete.
      assert {documents, units} in [{1, 1}, {0, 0}]
    end

    test "concurrent replaces naming the same documents in different orders do not deadlock" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "multi-doc-race-bank"}

      payload = fn n, ids ->
        %{
          "items" =>
            Enum.map(ids, fn id ->
              %{
                "content" => "body #{id} #{n}",
                "context" => "chat",
                "document_id" => id,
                "update_mode" => "replace"
              }
            end)
        }
      end

      assert {:ok, _} = Foresight.retain(ctx, payload.(0, ["doc-a", "doc-b"]))

      results =
        1..6
        |> Enum.map(fn n ->
          ids = if rem(n, 2) == 0, do: ["doc-a", "doc-b"], else: ["doc-b", "doc-a"]
          Task.async(fn -> Foresight.retain(ctx, payload.(n, ids)) end)
        end)
        |> Task.await_many(60_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      for id <- ["doc-a", "doc-b"] do
        assert {:ok, %{rows: [[1]]}} =
                 SQL.query(
                   Foresight.Repo,
                   "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1 AND document_ref = $2",
                   [ctx.bank, id]
                 )
      end
    end

    test "retain rejects metadata over the size cap before touching the database" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "caps-bank"}

      assert {:error, %Foresight.Error{reason: :invalid_request}} =
               Foresight.retain(ctx, %{
                 "items" => [
                   %{
                     "content" => "oversized",
                     "context" => "chat",
                     "metadata" => %{"blob" => String.duplicate("x", 70_000)}
                   }
                 ]
               })

      assert {:ok, %{rows: [[0]]}} =
               SQL.query(Foresight.Repo, "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1", [
                 ctx.bank
               ])
    end
  end

  describe "usage accounting" do
    setup do
      configure_store_engine!()

      engine = Application.get_env(:foresight, :engine)

      Application.put_env(
        :foresight,
        :engine,
        Keyword.put(engine, :embedder, Foresight.TestSupport.LedgerEmbedder)
      )

      :ok
    end

    test "retain and recall report the chargeable embedding calls they made" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "usage-bank"}

      assert {:ok, %{"usage" => usage}} =
               Foresight.retain(ctx, %{
                 "items" => [%{"content" => "usage body about Alice", "context" => "chat"}]
               })

      assert %{"calls" => calls, "failed_calls" => 0} = usage
      assert usage["total_tokens"] > 0
      assert Enum.all?(calls, &(&1["kind"] == "embedding" and &1["provider"] == "ledger-fake"))
      # At least the memory unit itself was embedded (entity names may add more).
      assert Enum.sum(Enum.map(calls, & &1["units"])) >= 1

      assert {:ok, %{"usage" => recall_usage, "results" => [_ | _]}} =
               Foresight.recall(ctx, %{"query" => "usage body"})

      assert [%{"kind" => "embedding", "units" => 1}] = recall_usage["calls"]
    end

    test "a retain with no chargeable call reports no usage" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "no-usage-bank"}

      engine = Application.get_env(:foresight, :engine)

      Application.put_env(
        :foresight,
        :engine,
        Keyword.put(engine, :embedder, Foresight.TestSupport.FakeEmbedder)
      )

      assert {:ok, %{"usage" => nil}} =
               Foresight.retain(ctx, %{
                 "items" => [%{"content" => "free body", "context" => "chat"}]
               })

      assert {:ok, response} = Foresight.recall(ctx, %{"query" => "free body"})
      refute Map.has_key?(response, "usage")
    end
  end

  describe "3072-dimension embeddings via halfvec" do
    setup do
      configure_store_engine!()
      :ok
    end

    test "a bank pinned to 3072 stores halfvec vectors and recalls through the halfvec index" do
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "bank-3072"}

      assert {:ok, _bank} = Foresight.put_bank(ctx, "bank-3072", %{"name" => "Bank 3072"})

      assert {:ok, _config} =
               Foresight.update_bank_config(ctx, "bank-3072", %{
                 "embed_model" => "openai/text-embedding-3-large",
                 "embedding_dim" => 3072
               })

      assert {:ok, %{"success" => true}} =
               Foresight.retain(ctx, %{
                 "async" => false,
                 "items" => [%{"content" => "gamma 3072 memory", "context" => "chat"}]
               })

      assert {:ok, %{"results" => [%{"text" => "gamma 3072 memory"}]}} =
               Foresight.recall(ctx, %{"query" => "gamma", "max_tokens" => 20})

      assert {:ok, %{rows: [[3072, "halfvec", 3072, true, true, true]]}} =
               SQL.query(
                 Foresight.Repo,
                 """
                 SELECT embedded_dim,
                        pg_typeof(embedding_3072)::text,
                        vector_dims(embedding_3072),
                        embedding_384 IS NULL,
                        embedding_1024 IS NULL,
                        embedding_1536 IS NULL
                 FROM memory_units
                 WHERE bank_id = $1
                 """,
                 [ctx.bank]
               )

      assert {:ok, %{rows: [[true]]}} =
               SQL.query(
                 Foresight.Repo,
                 """
                 SELECT indexdef LIKE '%hnsw%halfvec_cosine_ops%'
                 FROM pg_indexes
                 WHERE indexname = 'memory_units_embedding_3072_halfvec_cosine_ops_index'
                   AND schemaname = 'public'
                 """,
                 []
               )
    end
  end

  defp configure_store_engine! do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
    end)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()

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
  end

  defp entity_mentions(ctx) do
    {:ok, %{rows: rows}} =
      SQL.query(
        Foresight.Repo,
        "SELECT canonical_name, mention_count FROM entities WHERE bank_id = $1 ORDER BY 1",
        [ctx.bank]
      )

    rows
  end

  # Pairs are oriented by entity id, so compare them as sorted name pairs.
  defp link_weights(ctx) do
    {:ok, %{rows: rows}} =
      SQL.query(
        Foresight.Repo,
        """
        SELECT s.canonical_name, t.canonical_name, l.weight
        FROM entity_links l
        JOIN entities s ON s.id = l.source_entity_id
        JOIN entities t ON t.id = l.target_entity_id
        WHERE l.bank_id = $1
        """,
        [ctx.bank]
      )

    rows
    |> Enum.map(fn [source, target, weight] -> {Enum.sort([source, target]), weight} end)
    |> Enum.sort()
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)
end
