defmodule Foresight.Integration.SchemaParityTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.AsyncQueues.Oban, as: ObanQueue
  alias Foresight.Context
  alias Foresight.HTTP.Router
  alias Foresight.Jobs.ConsolidateWorker
  alias Foresight.Jobs.MigrateBankWorker
  alias Foresight.Jobs.ProbeBankWorker
  alias Foresight.Jobs.RetainWorker
  alias Foresight.Migration.BankMigrator
  alias Foresight.Migration.EmbeddingAudit
  alias Foresight.Migration.ParityProbe
  alias Foresight.Migration.VerbatimCopy
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.Directive
  alias Foresight.Schemas.Document
  alias Foresight.Schemas.Entity
  alias Foresight.Schemas.EntityLink
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Schemas.MemoryUnitEntity
  alias Foresight.Storage.Ecto, as: EctoStorage
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.TestSupport.PostgresHarness
  alias Oban.Job

  @moduletag :tier2

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])
    engine_config = Application.get_env(:foresight, :engine, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 10
      )
    )

    Application.put_env(
      :foresight,
      :engine,
      Keyword.merge(engine_config,
        storage: EctoStorage,
        repo: Foresight.Repo,
        embedder: Foresight.TestSupport.FakeEmbedder,
        reranker: Foresight.Rerankers.Passthrough,
        llm: Foresight.LLMs.Noop,
        queue: Foresight.TestSupport.FakeAsyncQueue
      )
    )

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      Application.put_env(:foresight, :engine, engine_config)
      PostgresHarness.stop!(harness)
    end)

    {:ok, harness: harness}
  end

  defp seed_test_embeddings!(prefix, bank_id, fill_value \\ 1.0) do
    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               """
               UPDATE "#{prefix}".memory_units AS mu
               SET embedding_384 =
                 CASE
                   WHEN mu.content = '' THEN array_fill(0.0::real, ARRAY[384])::vector
                   ELSE array_fill($2::real, ARRAY[384])::vector
                 END
               WHERE bank_id = $1
                 AND embedded_dim = 384
                 AND embedding_384 IS NULL
               """,
               [bank_id, fill_value]
             )
  end

  test "owns the head-enumerated schema surface" do
    assert {:ok, %{rows: rows}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT column_name
               FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'memory_units'
               ORDER BY column_name
               """,
               []
             )

    columns = MapSet.new(Enum.map(rows, &hd/1))

    for column <- ~w(
          bank_id
          fact_type
          content
          context
          embedding_384
          embedding_1024
          embedded_by
          embedded_dim
          occurred_start
          occurred_end
          mentioned_at
          tags
          proof_count
          source_memory_ids
          metadata
          search_tsv
          observation_scopes
        ) do
      assert MapSet.member?(columns, column), "expected memory_units.#{column} to exist"
    end

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
    refute definition =~ "opinion"
    refute definition =~ "bank"

    assert {:ok, %{rows: index_rows}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT indexname, indexdef
               FROM pg_indexes
               WHERE schemaname = 'public' AND tablename = 'memory_units'
               ORDER BY indexname
               """,
               []
             )

    indexes = Map.new(index_rows, fn [name, definition] -> {name, definition} end)

    assert Enum.any?(indexes, fn {_name, definition} ->
             String.contains?(definition, "USING hnsw") and
               String.contains?(definition, "embedding_384")
           end)

    assert Enum.any?(indexes, fn {_name, definition} ->
             String.contains?(definition, "USING hnsw") and
               String.contains?(definition, "embedding_1024")
           end)

    assert Enum.any?(indexes, fn {_name, definition} ->
             String.contains?(definition, "USING gin") and String.contains?(definition, "(tags)")
           end)

    assert Map.has_key?(indexes, "memory_units_bank_world_idx")
    assert Map.has_key?(indexes, "memory_units_bank_experience_idx")
    assert Map.has_key?(indexes, "memory_units_bank_observation_idx")

    assert {:ok, %{rows: document_rows}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT column_name
               FROM information_schema.columns
               WHERE table_schema = 'public' AND table_name = 'documents'
               ORDER BY column_name
               """,
               []
             )

    document_columns = MapSet.new(Enum.map(document_rows, &hd/1))

    for column <- ~w(
          external_id
          original_text
          content_hash
          file_storage_key
          file_original_name
          file_content_type
        ) do
      assert MapSet.member?(document_columns, column), "expected documents.#{column} to exist"
    end
  end

  test "prefixed migration tracking stays schema-local and replay is a no-op" do
    prefix = "tenant_template"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_template", [])

    {:ok, migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    expected_count = length(migrated)
    assert expected_count > 0

    assert {:ok, %{rows: [[^expected_count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_template.schema_migrations",
               []
             )

    assert {:ok, %{rows: [[^expected_count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.schema_migrations",
               []
             )

    {:ok, replayed, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    assert replayed == []

    assert {:ok, %{rows: [[^expected_count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_template.schema_migrations",
               []
             )

    assert {:ok, %{rows: [[^expected_count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.schema_migrations",
               []
             )
  end

  test "schema provisioner creates and replays a tenant schema safely" do
    prefix = "tenant_provisioned"

    assert {:ok, %{prefix: ^prefix, migrated_versions: migrated_versions}} =
             SchemaProvisioner.provision(prefix, repo: Foresight.Repo)

    expected_count = length(migrated_versions)
    assert expected_count > 0

    assert {:ok, %{rows: [[^expected_count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_provisioned.schema_migrations",
               []
             )

    assert {:ok, %{prefix: ^prefix, migrated_versions: []}} =
             SchemaProvisioner.provision(prefix, repo: Foresight.Repo)

    assert {:error, :invalid_prefix} =
             SchemaProvisioner.provision("tenant-bad-name", repo: Foresight.Repo)

    assert {:ok, %{rows: [[false]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT EXISTS (
                 SELECT 1
                 FROM information_schema.schemata
                 WHERE schema_name = 'tenant-bad-name'
               )
               """,
               []
             )
  end

  test "embedding audit fails closed on unsupported embedded dimensions" do
    compatible_prefix = "tenant_embed_ok"
    incompatible_prefix = "tenant_embed_bad"

    assert {:ok, _} = SchemaProvisioner.provision(compatible_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(incompatible_prefix, repo: Foresight.Repo)

    for {prefix, embedded_dim} <- [{compatible_prefix, 384}, {incompatible_prefix, 4096}] do
      {:ok, _bank} =
        %Bank{}
        |> Bank.changeset(%{id: "bank-a", name: "Bank A", mission: ""})
        |> Foresight.Repo.insert(prefix: prefix)

      {:ok, _memory} =
        %MemoryUnit{}
        |> MemoryUnit.changeset(%{
          bank_id: "bank-a",
          fact_type: :experience,
          content: "alpha note",
          context: "chat",
          tags: ["alpha"],
          embedded_by: "test",
          embedded_dim: embedded_dim,
          mentioned_at: ~U[2026-01-01 00:00:00Z]
        })
        |> Foresight.Repo.insert(prefix: prefix)
    end

    assert {:ok,
            %{
              prefix: ^compatible_prefix,
              configured_embedding_model: "BAAI/bge-small-en-v1.5",
              pinned_default_model: "BAAI/bge-small-en-v1.5",
              pinned_default_dimension: 384,
              pinned_default_match?: true,
              row_count: 1,
              embedded_dims: [384],
              embedding_columns: [384, 1024, 1536, 3072],
              table_audits: [
                %{
                  bank_id: "bank-a",
                  table: "memory_units",
                  row_count: 1,
                  embedded_dims: [384],
                  embedded_by: ["test"],
                  vector_dimensions: [384, 1024, 1536, 3072],
                  pinned_default_dimension_match?: true,
                  compatible?: true
                }
              ],
              compatible?: true
            }} = EmbeddingAudit.audit_schema(compatible_prefix, repo: Foresight.Repo)

    assert {:ok,
            %{
              prefix: ^incompatible_prefix,
              configured_embedding_model: "BAAI/bge-small-en-v1.5",
              pinned_default_model: "BAAI/bge-small-en-v1.5",
              pinned_default_dimension: 384,
              pinned_default_match?: false,
              row_count: 1,
              embedded_dims: [4096],
              embedding_columns: [384, 1024, 1536, 3072],
              table_audits: [
                %{
                  bank_id: "bank-a",
                  table: "memory_units",
                  row_count: 1,
                  embedded_dims: [4096],
                  embedded_by: ["test"],
                  vector_dimensions: [384, 1024, 1536, 3072],
                  pinned_default_dimension_match?: false,
                  compatible?: false
                }
              ],
              compatible?: false
            }} = EmbeddingAudit.audit_schema(incompatible_prefix, repo: Foresight.Repo)
  end

  test "embedding audit scopes to the bank being migrated and reports bank table details" do
    prefix = "tenant_embed_scope"

    assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Foresight.Repo)

    for {bank_id, embedded_dim, embedded_by} <- [
          {"bank-good", 384, "BAAI/bge-small-en-v1.5"},
          {"bank-other", 384, "custom/model"}
        ] do
      {:ok, _bank} =
        %Bank{}
        |> Bank.changeset(%{id: bank_id, name: bank_id, mission: ""})
        |> Foresight.Repo.insert(prefix: prefix)

      {:ok, _memory} =
        %MemoryUnit{}
        |> MemoryUnit.changeset(%{
          bank_id: bank_id,
          fact_type: :experience,
          content: "alpha note",
          context: "chat",
          tags: ["alpha"],
          embedded_by: embedded_by,
          embedded_dim: embedded_dim,
          mentioned_at: ~U[2026-01-01 00:00:00Z]
        })
        |> Foresight.Repo.insert(prefix: prefix)
    end

    assert {:ok,
            %{
              prefix: ^prefix,
              configured_embedding_model: "BAAI/bge-small-en-v1.5",
              pinned_default_match?: true,
              row_count: 1,
              embedded_dims: [384],
              embedding_columns: [384, 1024, 1536, 3072],
              table_audits: [
                %{
                  bank_id: "bank-good",
                  table: "memory_units",
                  row_count: 1,
                  embedded_dims: [384],
                  embedded_by: ["BAAI/bge-small-en-v1.5"],
                  vector_dimensions: [384, 1024, 1536, 3072],
                  pinned_default_dimension_match?: true,
                  compatible?: true
                }
              ],
              compatible?: true
            }} =
             EmbeddingAudit.audit_schema(prefix,
               repo: Foresight.Repo,
               bank_id: "bank-good"
             )

    assert {:ok,
            %{
              prefix: ^prefix,
              configured_embedding_model: "custom/model",
              pinned_default_match?: false,
              row_count: 1,
              embedded_dims: [384],
              embedding_columns: [384, 1024, 1536, 3072],
              table_audits: [
                %{
                  bank_id: "bank-other",
                  table: "memory_units",
                  row_count: 1,
                  embedded_dims: [384],
                  embedded_by: ["custom/model"],
                  vector_dimensions: [384, 1024, 1536, 3072],
                  pinned_default_dimension_match?: true,
                  compatible?: true
                }
              ],
              compatible?: false
            }} =
             EmbeddingAudit.audit_schema(prefix,
               repo: Foresight.Repo,
               bank_id: "bank-other"
             )
  end

  test "verbatim copy migrates a compatible bank between tenant schemas" do
    source_prefix = "tenant_copy_source"
    target_prefix = "tenant_copy_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, directive} =
      %Directive{}
      |> Directive.changeset(%{
        bank_id: "bank-copy",
        name: "Be concise",
        content: "Prefer concise answers",
        priority: 10,
        is_active: true,
        tags: ["copy"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, webhook} =
      %Foresight.Schemas.Webhook{}
      |> Foresight.Schemas.Webhook.changeset(%{
        bank_id: "bank-copy",
        url: "https://example.test/hooks/copy",
        secret: "copy-secret",
        event_types: ["memory.retained", "memory.consolidated"],
        enabled: true
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-copy",
        external_id: "doc-copy",
        title: "Copy Doc",
        original_text: "copy source text",
        content_hash: "hash-copy",
        file_storage_key: "file-copy"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-copy",
        data: "copy-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        document_ref: "doc-copy",
        embedded_by: inspect(Foresight.TestSupport.FakeEmbedder),
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-copy",
        canonical_name: "Copy Alice",
        normalized_name: "copy alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _link} =
      %MemoryUnitEntity{}
      |> MemoryUnitEntity.changeset(%{
        memory_unit_id: memory.id,
        entity_id: entity.id
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _entity_link} =
      %EntityLink{}
      |> EntityLink.changeset(%{
        bank_id: "bank-copy",
        source_entity_id: entity.id,
        target_entity_id: entity.id,
        link_type: "co_occurrence",
        weight: 1
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-copy")

    assert {:ok,
            %{
              bank_id: "bank-copy",
              copied_banks: 1,
              copied_directives: 1,
              copied_webhooks: 1,
              copied_file_storage: 1,
              copied_documents: 1,
              copied_memory_units: 1,
              copied_entities: 1,
              copied_memory_unit_entities: 1,
              copied_entity_links: 1
            }} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [["Source Bank", "Source mission"]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT name, mission FROM tenant_copy_target.banks WHERE id = 'bank-copy'",
               []
             )

    assert {:ok, %{rows: [["Be concise", "Prefer concise answers", 10, true]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT name, content, priority, is_active
               FROM tenant_copy_target.directives
               WHERE id::text = $1
               """,
               [directive.id]
             )

    assert {:ok,
            %{
              rows: [
                [
                  "https://example.test/hooks/copy",
                  "copy-secret",
                  ["memory.retained", "memory.consolidated"],
                  true
                ]
              ]
            }} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT url, secret, event_types, enabled
               FROM tenant_copy_target.webhooks
               WHERE id::text = $1
               """,
               [webhook.id]
             )

    assert {:ok, %{rows: [["copy-binary"]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT convert_from(data, 'UTF8') FROM tenant_copy_target.file_storage WHERE storage_key = 'file-copy'",
               []
             )

    assert {:ok, %{rows: [["Copy Doc", "doc-copy", "file-copy"]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT title, external_id, file_storage_key
               FROM tenant_copy_target.documents
               WHERE bank_id = 'bank-copy'
               """,
               []
             )

    assert {:ok, %{rows: [["copied note", 384, "doc-copy"]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT content, embedded_dim, document_ref
               FROM tenant_copy_target.memory_units
               WHERE bank_id = 'bank-copy'
               """,
               []
             )

    assert {:ok, %{rows: [["Copy Alice", 1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT canonical_name, mention_count FROM tenant_copy_target.entities WHERE bank_id = 'bank-copy'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT count(*)
               FROM tenant_copy_target.memory_unit_entities
               WHERE memory_unit_id::text = $1 AND entity_id::text = $2
               """,
               [memory.id, entity.id]
             )

    assert {:ok, %{rows: [["co_occurrence", 1]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT link_type, weight
               FROM tenant_copy_target.entity_links
               WHERE bank_id = 'bank-copy'
               """,
               []
             )
  end

  test "verbatim copy reassigns target owners before a rerun" do
    suffix = System.unique_integer([:positive])
    source_prefix = "tenant_copy_owner_source_#{suffix}"
    target_prefix = "tenant_copy_owner_target_#{suffix}"
    role_name = "copy_owner_#{suffix}"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    assert {:ok, %{rows: [[current_user]]}} = SQL.query(Foresight.Repo, "SELECT current_user", [])
    assert {:ok, _} = SQL.query(Foresight.Repo, ~s(CREATE ROLE "#{role_name}" NOLOGIN), [])

    on_exit(fn ->
      SQL.query(Foresight.Repo, ~s(DROP ROLE IF EXISTS "#{role_name}"), [])
    end)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        embedded_by: inspect(Foresight.TestSupport.FakeEmbedder),
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               ~s(ALTER SCHEMA "#{target_prefix}" OWNER TO "#{role_name}"),
               []
             )

    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               ~s(ALTER TABLE "#{target_prefix}".banks OWNER TO "#{role_name}"),
               []
             )

    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               ~s(ALTER TABLE "#{target_prefix}".memory_units OWNER TO "#{role_name}"),
               []
             )

    seed_test_embeddings!(source_prefix, "bank-copy")

    assert {:ok, %{copied_banks: 1, copied_memory_units: 1}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[^current_user]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT pg_get_userbyid(nspowner)
               FROM pg_namespace
               WHERE nspname = $1
               """,
               [target_prefix]
             )

    assert {:ok, %{rows: [[^current_user], [^current_user]]}} =
             SQL.query(
               Foresight.Repo,
               """
               SELECT pg_get_userbyid(c.relowner)
               FROM pg_class AS c
               INNER JOIN pg_namespace AS n
                 ON n.oid = c.relnamespace
               WHERE n.nspname = $1
                 AND c.relname IN ('banks', 'memory_units')
               ORDER BY c.relname
               """,
               [target_prefix]
             )
  end

  test "verbatim copy fails closed on unsupported embedded dimensions" do
    source_prefix = "tenant_copy_bad_source"
    target_prefix = "tenant_copy_bad_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Bad Source", mission: "Bad mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "bad copied note",
        context: "chat",
        tags: ["copy"],
        embedded_by: "test",
        embedded_dim: 4096,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:error,
            {:incompatible_embedding_dimensions,
             %{
               prefix: ^source_prefix,
               row_count: 1,
               embedded_dims: [4096],
               embedding_columns: [384, 1024, 1536, 3072],
               compatible?: false
             }}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_copy_bad_target.banks WHERE id = 'bank-copy'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_copy_bad_target.memory_units WHERE bank_id = 'bank-copy'",
               []
             )
  end

  test "verbatim copy fails closed on memory units without a target-compatible stored vector" do
    source_prefix = "tenant_copy_missing_vector_source"
    target_prefix = "tenant_copy_missing_vector_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               """
               UPDATE "#{source_prefix}".memory_units
               SET embedding_384 = NULL
               WHERE bank_id = 'bank-copy'
               """,
               []
             )

    assert {:error,
            {:incompatible_embedding_rows,
             %{
               bank_id: "bank-copy",
               total_rows: 1,
               eligible_rows: 0,
               target_embedding_columns: [384, 1024, 1536, 3072]
             }}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )
  end

  test "verbatim copy fails closed on missing bank document references" do
    source_prefix = "tenant_copy_bad_doc_source"
    target_prefix = "tenant_copy_bad_doc_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        document_ref: "doc-missing",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:error,
            {:incomplete_dependent_rows,
             %{
               bank_id: "bank-copy",
               dependency: :document_refs,
               total_rows: 1,
               eligible_rows: 0
             }}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_copy_bad_doc_target.banks WHERE id = 'bank-copy'",
               []
             )
  end

  test "verbatim copy fails closed on missing bank file storage" do
    source_prefix = "tenant_copy_bad_file_source"
    target_prefix = "tenant_copy_bad_file_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-copy",
        external_id: "doc-copy",
        title: "Copy Doc",
        original_text: "copy source text",
        content_hash: "hash-copy",
        file_storage_key: "file-missing"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        document_ref: "doc-copy",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:error,
            {:incomplete_dependent_rows,
             %{
               bank_id: "bank-copy",
               dependency: :file_storage,
               total_rows: 1,
               eligible_rows: 0
             }}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_copy_bad_file_target.banks WHERE id = 'bank-copy'",
               []
             )
  end

  test "verbatim copy fails closed on cross-bank memory unit entity rows" do
    source_prefix = "tenant_copy_incomplete_mue_source"
    target_prefix = "tenant_copy_incomplete_mue_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _other_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-other", name: "Other Bank", mission: "Other mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, other_entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-other",
        canonical_name: "Other Alice",
        normalized_name: "other alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _cross_bank_link} =
      %MemoryUnitEntity{}
      |> MemoryUnitEntity.changeset(%{
        memory_unit_id: memory.id,
        entity_id: other_entity.id
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:error,
            {:incomplete_dependent_rows,
             %{
               bank_id: "bank-copy",
               dependency: :memory_unit_entities,
               total_rows: 1,
               eligible_rows: 0
             }}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_copy_incomplete_mue_target.banks WHERE id = 'bank-copy'",
               []
             )
  end

  test "verbatim copy fails closed on cross-bank entity link rows" do
    source_prefix = "tenant_copy_incomplete_el_source"
    target_prefix = "tenant_copy_incomplete_el_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-copy", name: "Source Bank", mission: "Source mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _other_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-other", name: "Other Bank", mission: "Other mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-copy",
        fact_type: :experience,
        content: "copied note",
        context: "chat",
        tags: ["copy"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-copy",
        canonical_name: "Copy Alice",
        normalized_name: "copy alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, other_entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-other",
        canonical_name: "Other Alice",
        normalized_name: "other alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _cross_bank_link} =
      %EntityLink{}
      |> EntityLink.changeset(%{
        bank_id: "bank-copy",
        source_entity_id: entity.id,
        target_entity_id: other_entity.id,
        link_type: "co_occurrence",
        weight: 1
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:error,
            {:incomplete_dependent_rows,
             %{
               bank_id: "bank-copy",
               dependency: :entity_links,
               total_rows: 1,
               eligible_rows: 0
             }}} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-copy",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_copy_incomplete_el_target.banks WHERE id = 'bank-copy'",
               []
             )
  end

  test "bank migrator provisions, audits, and copies in one tracked step" do
    source_prefix = "tenant_migrate_source"
    target_prefix = "tenant_migrate_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _directive} =
      %Directive{}
      |> Directive.changeset(%{
        bank_id: "bank-migrate",
        name: "Stay grounded",
        content: "Answer only from grounded memory",
        priority: 5,
        is_active: true,
        tags: ["migrate"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _webhook} =
      %Foresight.Schemas.Webhook{}
      |> Foresight.Schemas.Webhook.changeset(%{
        bank_id: "bank-migrate",
        url: "https://example.test/hooks/migrate",
        secret: "migrate-secret",
        event_types: ["memory.retained"],
        enabled: true
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate",
        external_id: "doc-migrate",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate",
        file_storage_key: "file-migrate"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate",
        data: "migrate-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate",
        # Must match the model recall resolves (app :ml model_id) — recall filters
        # candidates on embedded_by == profile model_id — otherwise the copied unit
        # is filtered out of the post-migrate recall assertion below.
        embedded_by: "BAAI/bge-small-en-v1.5",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-migrate",
        canonical_name: "Migrated Alice",
        normalized_name: "migrated alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _link} =
      %MemoryUnitEntity{}
      |> MemoryUnitEntity.changeset(%{
        memory_unit_id: memory.id,
        entity_id: entity.id
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _entity_link} =
      %EntityLink{}
      |> EntityLink.changeset(%{
        bank_id: "bank-migrate",
        source_entity_id: entity.id,
        target_entity_id: entity.id,
        link_type: "co_occurrence",
        weight: 1
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:ok,
            %{
              bank_id: "bank-migrate",
              source_prefix: ^source_prefix,
              target_prefix: ^target_prefix,
              target_provisioned: %{prefix: ^target_prefix},
              source_audit: %{
                prefix: ^source_prefix,
                row_count: 1,
                embedded_dims: [384],
                embedding_columns: [384, 1024, 1536, 3072],
                compatible?: true
              },
              copy_result: %{
                bank_id: "bank-migrate",
                copied_banks: 1,
                copied_directives: 1,
                copied_webhooks: 1,
                copied_file_storage: 1,
                copied_documents: 1,
                copied_memory_units: 1,
                copied_entities: 1,
                copied_memory_unit_entities: 1,
                copied_entity_links: 1
              },
              parity_probe: %{
                bank_id: "bank-migrate",
                bank_match?: true,
                source_directive_count: 1,
                target_directive_count: 1,
                source_webhook_count: 1,
                target_webhook_count: 1,
                source_file_storage_count: 1,
                target_file_storage_count: 1,
                missing_directive_ids: [],
                extra_directive_ids: [],
                mismatched_directive_ids: [],
                missing_webhook_ids: [],
                extra_webhook_ids: [],
                mismatched_webhook_ids: [],
                source_document_count: 1,
                target_document_count: 1,
                source_memory_unit_count: 1,
                target_memory_unit_count: 1,
                source_entity_count: 1,
                target_entity_count: 1,
                source_memory_unit_entity_count: 1,
                target_memory_unit_entity_count: 1,
                source_entity_link_count: 1,
                target_entity_link_count: 1,
                missing_file_storage_keys: [],
                extra_file_storage_keys: [],
                mismatched_file_storage_keys: [],
                missing_document_ids: [],
                extra_document_ids: [],
                mismatched_document_ids: [],
                missing_in_target: [],
                extra_in_target: [],
                mismatched_memory_unit_ids: [],
                missing_entity_ids: [],
                extra_entity_ids: [],
                mismatched_entity_ids: [],
                missing_memory_unit_entities: [],
                extra_memory_unit_entities: [],
                missing_entity_links: [],
                extra_entity_links: [],
                cosine_threshold: 0.99,
                minimum_cosine: minimum_cosine,
                cosine_failures: [],
                cosine_pass?: true,
                clean?: true
              },
              source_cleanup: %{
                bank_id: "bank-migrate",
                source_prefix: ^source_prefix,
                deleted_banks: 1,
                deleted_directives: 1,
                deleted_webhooks: 1,
                deleted_file_storage: 1,
                deleted_documents: 1,
                deleted_memory_units: 1,
                deleted_entities: 1,
                deleted_memory_unit_entities: 1,
                deleted_entity_links: 1
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert minimum_cosine >= 0.99

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_target.banks WHERE id = 'bank-migrate'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_target.memory_units WHERE bank_id = 'bank-migrate'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_source.banks WHERE id = 'bank-migrate'",
               []
             )

    ctx = %Context{
      tenant_id: "tenant-migrate",
      mode: :mode_b,
      bank: "bank-migrate",
      prefix: target_prefix
    }

    assert {:ok, %{"results" => [result | _]}} =
             EctoStorage.recall(
               ctx,
               %{"query" => "migrated", "max_tokens" => 200},
               repo: Foresight.Repo,
               embedder: Foresight.TestSupport.FakeEmbedder,
               reranker: Foresight.Rerankers.Passthrough
             )

    assert result["text"] == "migrated note"
  end

  test "bank migrator fails closed on cosine probe miss and keeps the source rows" do
    source_prefix = "tenant_migrate_cosine_miss_source"
    target_prefix = "tenant_migrate_cosine_miss_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate", 0.0)

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-migrate",
               detail: %{
                 clean?: false,
                 cosine_threshold: 0.99,
                 minimum_cosine: minimum_cosine,
                 cosine_pass?: false,
                 cosine_failures: [%{memory_unit_id: _, cosine: cosine, threshold: 0.99}]
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert minimum_cosine < 0.99
    assert cosine < 0.99

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_cosine_miss_source.banks WHERE id = 'bank-migrate'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_cosine_miss_source.memory_units WHERE bank_id = 'bank-migrate'",
               []
             )
  end

  test "bank migrator fails closed before copy on incompatible source audit" do
    source_prefix = "tenant_migrate_bad_source"
    target_prefix = "tenant_migrate_bad_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Bad Migrated Bank", mission: "Bad mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "bad migrated note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 4096,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :audit,
               failure_kind: :incompatible_source_audit,
               bank_id: "bank-migrate",
               source_prefix: ^source_prefix,
               target_prefix: ^target_prefix,
               source_audit: %{
                 prefix: ^source_prefix,
                 row_count: 1,
                 embedded_dims: [4096],
                 embedding_columns: [384, 1024, 1536, 3072],
                 compatible?: false
               },
               detail: %{
                 prefix: ^source_prefix,
                 row_count: 1,
                 embedded_dims: [4096],
                 embedding_columns: [384, 1024, 1536, 3072],
                 compatible?: false
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_bad_target.banks WHERE id = 'bank-migrate'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_bad_target.memory_units WHERE bank_id = 'bank-migrate'",
               []
             )
  end

  test "bank migrator fails closed on incomplete dependent rows" do
    source_prefix = "tenant_migrate_incomplete_source"
    target_prefix = "tenant_migrate_incomplete_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _other_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-other", name: "Other Bank", mission: "Other mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, other_entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-other",
        canonical_name: "Other Alice",
        normalized_name: "other alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _cross_bank_link} =
      %MemoryUnitEntity{}
      |> MemoryUnitEntity.changeset(%{
        memory_unit_id: memory.id,
        entity_id: other_entity.id
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :copy,
               failure_kind: :incomplete_dependent_rows,
               bank_id: "bank-migrate",
               source_prefix: ^source_prefix,
               target_prefix: ^target_prefix,
               target_provisioned: %{prefix: ^target_prefix},
               source_audit: %{
                 prefix: ^source_prefix,
                 row_count: 1,
                 embedded_dims: [384],
                 embedding_columns: [384, 1024, 1536, 3072],
                 compatible?: true
               },
               detail: %{
                 bank_id: "bank-migrate",
                 dependency: :memory_unit_entities,
                 total_rows: 1,
                 eligible_rows: 0
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_incomplete_target.banks WHERE id = 'bank-migrate'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_migrate_incomplete_target.memory_units WHERE bank_id = 'bank-migrate'",
               []
             )
  end

  test "bank migrator reports structured diagnostics for parity probe failures" do
    source_prefix = "tenant_migrate_probe_source"
    target_prefix = "tenant_migrate_probe_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _target_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _extra_target_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "extra target note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-02 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-migrate",
               source_prefix: ^source_prefix,
               target_prefix: ^target_prefix,
               target_provisioned: %{prefix: ^target_prefix},
               source_audit: %{
                 prefix: ^source_prefix,
                 row_count: 1,
                 embedded_dims: [384],
                 embedding_columns: [384, 1024, 1536, 3072],
                 compatible?: true
               },
               copy_result: %{
                 bank_id: "bank-migrate",
                 copied_banks: 0,
                 copied_memory_units: 1,
                 copied_entities: 0,
                 copied_memory_unit_entities: 0,
                 copied_entity_links: 0
               },
               detail: %{
                 bank_id: "bank-migrate",
                 clean?: false,
                 source_memory_unit_count: 1,
                 target_memory_unit_count: 2,
                 extra_in_target: [_]
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )
  end

  test "bank migrator resumes partial target copies before source cleanup" do
    suffix = System.unique_integer([:positive])
    source_prefix = "tenant_migrate_resume_source_#{suffix}"
    target_prefix = "tenant_migrate_resume_target_#{suffix}"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_directive} =
      %Directive{}
      |> Directive.changeset(%{
        bank_id: "bank-migrate",
        name: "Stay grounded",
        content: "Answer only from grounded memory",
        priority: 5,
        is_active: true,
        tags: ["migrate"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate",
        external_id: "doc-migrate",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate",
        file_storage_key: "file-migrate"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate",
        data: "migrate-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-migrate",
        canonical_name: "Migrated Alice",
        normalized_name: "migrated alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _link} =
      %MemoryUnitEntity{}
      |> MemoryUnitEntity.changeset(%{
        memory_unit_id: memory.id,
        entity_id: entity.id
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _entity_link} =
      %EntityLink{}
      |> EntityLink.changeset(%{
        bank_id: "bank-migrate",
        source_entity_id: entity.id,
        target_entity_id: entity.id,
        link_type: "co_occurrence",
        weight: 1
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _target_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _target_directive} =
      %Directive{id: source_directive.id}
      |> Directive.changeset(%{
        bank_id: "bank-migrate",
        name: "Stay grounded",
        content: "Answer only from grounded memory",
        priority: 5,
        is_active: true,
        tags: ["migrate"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _target_document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate",
        external_id: "doc-migrate",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate",
        file_storage_key: "file-migrate"
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _target_file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate",
        data: "migrate-binary"
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:ok,
            %{
              copy_result: %{
                copied_banks: 0,
                copied_directives: 0,
                copied_file_storage: 0,
                copied_documents: 0,
                copied_memory_units: 1,
                copied_entities: 1,
                copied_memory_unit_entities: 1,
                copied_entity_links: 1
              },
              parity_probe: %{
                clean?: true,
                source_directive_count: 1,
                target_directive_count: 1,
                source_file_storage_count: 1,
                target_file_storage_count: 1,
                source_document_count: 1,
                target_document_count: 1,
                source_memory_unit_count: 1,
                target_memory_unit_count: 1,
                source_entity_count: 1,
                target_entity_count: 1,
                source_memory_unit_entity_count: 1,
                target_memory_unit_entity_count: 1,
                source_entity_link_count: 1,
                target_entity_link_count: 1
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[count]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{source_prefix}.banks WHERE id = 'bank-migrate'",
               []
             )

    assert count == 0
  end

  test "bank migrator converges after probe-stage drift is corrected" do
    source_prefix = "tenant_migrate_probe_recover_source"
    target_prefix = "tenant_migrate_probe_recover_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate",
        external_id: "doc-migrate",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate",
        file_storage_key: "file-migrate"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate",
        data: "migrate-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _target_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _extra_target_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "extra target note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-02 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-migrate",
               detail: %{
                 clean?: false,
                 source_memory_unit_count: 1,
                 target_memory_unit_count: 2,
                 extra_in_target: [_]
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert {1, nil} =
             from(unit in MemoryUnit,
               where: unit.bank_id == "bank-migrate" and unit.content == "extra target note"
             )
             |> Foresight.Repo.delete_all(prefix: target_prefix)

    assert {:ok,
            %{
              copy_result: %{
                copied_banks: 0,
                copied_file_storage: 0,
                copied_documents: 0,
                copied_memory_units: 0,
                copied_entities: 0,
                copied_memory_unit_entities: 0,
                copied_entity_links: 0
              },
              parity_probe: %{
                clean?: true,
                source_file_storage_count: 1,
                target_file_storage_count: 1,
                source_document_count: 1,
                target_document_count: 1,
                source_memory_unit_count: 1,
                target_memory_unit_count: 1
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )
  end

  test "bank migrator converges after source dependency gaps are corrected" do
    source_prefix = "tenant_migrate_dependency_recover_source"
    target_prefix = "tenant_migrate_dependency_recover_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate",
        external_id: "doc-migrate",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate",
        file_storage_key: "file-migrate"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :copy,
               failure_kind: :incomplete_dependent_rows,
               bank_id: "bank-migrate",
               detail: %{
                 bank_id: "bank-migrate",
                 dependency: :file_storage,
                 total_rows: 1,
                 eligible_rows: 0
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    {:ok, _source_file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate",
        data: "migrate-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate")

    assert {:ok,
            %{
              copy_result: %{
                copied_banks: 1,
                copied_file_storage: 1,
                copied_documents: 1,
                copied_memory_units: 1,
                copied_entities: 0,
                copied_memory_unit_entities: 0,
                copied_entity_links: 0
              },
              parity_probe: %{
                clean?: true,
                source_file_storage_count: 1,
                target_file_storage_count: 1,
                source_document_count: 1,
                target_document_count: 1,
                source_memory_unit_count: 1,
                target_memory_unit_count: 1,
                source_entity_count: 0,
                target_entity_count: 0,
                source_memory_unit_entity_count: 0,
                target_memory_unit_entity_count: 0,
                source_entity_link_count: 0,
                target_entity_link_count: 0
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )
  end

  test "parity probe detects post-copy target drift" do
    source_prefix = "tenant_probe_source"
    target_prefix = "tenant_probe_target"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-probe", name: "Probe Bank", mission: "Probe mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_directive} =
      %Directive{}
      |> Directive.changeset(%{
        bank_id: "bank-probe",
        name: "Probe directive",
        content: "Keep the answer grounded",
        priority: 3,
        is_active: true,
        tags: ["probe"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_webhook} =
      %Foresight.Schemas.Webhook{}
      |> Foresight.Schemas.Webhook.changeset(%{
        bank_id: "bank-probe",
        url: "https://example.test/hooks/probe",
        secret: "probe-secret",
        event_types: ["memory.retained"],
        enabled: true
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _document} =
      %Foresight.Schemas.Document{}
      |> Document.changeset(%{
        bank_id: "bank-probe",
        external_id: "doc-probe",
        title: "Probe Doc",
        original_text: "probe source text",
        content_hash: "hash-probe",
        file_storage_key: "file-probe"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-probe",
        data: "probe-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-probe",
        fact_type: :experience,
        content: "probe note",
        context: "chat",
        tags: ["probe"],
        document_ref: "doc-probe",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_entity} =
      %Entity{}
      |> Entity.changeset(%{
        bank_id: "bank-probe",
        canonical_name: "Probe Alice",
        normalized_name: "probe alice",
        mention_count: 1,
        first_seen: ~U[2026-01-01 00:00:00Z],
        last_seen: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _link} =
      %MemoryUnitEntity{}
      |> MemoryUnitEntity.changeset(%{
        memory_unit_id: source_memory.id,
        entity_id: source_entity.id
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _entity_link} =
      %EntityLink{}
      |> EntityLink.changeset(%{
        bank_id: "bank-probe",
        source_entity_id: source_entity.id,
        target_entity_id: source_entity.id,
        link_type: "co_occurrence",
        weight: 1
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-probe")

    assert {:ok,
            %{
              copied_directives: 1,
              copied_webhooks: 1,
              copied_file_storage: 1,
              copied_documents: 1,
              copied_memory_units: 1,
              copied_entities: 1,
              copied_memory_unit_entities: 1,
              copied_entity_links: 1
            }} =
             VerbatimCopy.copy_bank(source_prefix, target_prefix, "bank-probe",
               repo: Foresight.Repo
             )

    assert {1, nil} =
             from(unit in MemoryUnit, where: unit.id == ^source_memory.id)
             |> Foresight.Repo.update_all([set: [content: "drifted note"]], prefix: target_prefix)

    assert {1, nil} =
             from(directive in Directive, where: directive.id == ^source_directive.id)
             |> Foresight.Repo.update_all([set: [content: "drifted directive"]],
               prefix: target_prefix
             )

    assert {1, nil} =
             from(webhook in Foresight.Schemas.Webhook, where: webhook.id == ^source_webhook.id)
             |> Foresight.Repo.update_all([set: [secret: "drifted-secret"]],
               prefix: target_prefix
             )

    assert {:ok,
            %{
              bank_id: "bank-probe",
              bank_match?: true,
              source_directive_count: 1,
              target_directive_count: 1,
              missing_directive_ids: [],
              extra_directive_ids: [],
              mismatched_directive_ids: [directive_mismatch_id],
              source_webhook_count: 1,
              target_webhook_count: 1,
              missing_webhook_ids: [],
              extra_webhook_ids: [],
              mismatched_webhook_ids: [webhook_mismatch_id],
              source_file_storage_count: 1,
              target_file_storage_count: 1,
              missing_file_storage_keys: [],
              extra_file_storage_keys: [],
              mismatched_file_storage_keys: [],
              source_document_count: 1,
              target_document_count: 1,
              missing_document_ids: [],
              extra_document_ids: [],
              mismatched_document_ids: [],
              source_memory_unit_count: 1,
              target_memory_unit_count: 1,
              missing_in_target: [],
              extra_in_target: [],
              mismatched_memory_unit_ids: [mismatch_id],
              clean?: false
            }} =
             ParityProbe.probe_bank(source_prefix, target_prefix, "bank-probe",
               repo: Foresight.Repo
             )

    assert mismatch_id == source_memory.id
    assert directive_mismatch_id == source_directive.id
    assert webhook_mismatch_id == source_webhook.id
  end

  test "probe_bank_migration fails cleanly on parity drift without invoking copy" do
    suffix = System.unique_integer([:positive])
    source_prefix = "tenant_probe_api_source_#{suffix}"
    target_prefix = "tenant_probe_api_target_#{suffix}"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-probe-api", name: "Probe API Bank"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-probe-api",
        fact_type: :world,
        content: "source-only note",
        context: "probe-api",
        embedded_by: "test",
        embedded_dim: 384,
        metadata: %{"origin" => "source"},
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "bank-probe-api"}

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-probe-api",
               source_prefix: ^source_prefix,
               target_prefix: ^target_prefix,
               target_provisioned: %{prefix: ^target_prefix},
               source_audit: %{compatible?: true},
               detail: %{clean?: false, missing_in_target: [_]}
             }}} =
             Foresight.probe_bank_migration(ctx, %{
               "source_prefix" => source_prefix,
               "target_prefix" => target_prefix
             })

    assert [] ==
             from(bank in Bank, where: bank.id == "bank-probe-api", select: bank.id)
             |> Foresight.Repo.all(prefix: target_prefix)

    assert [] ==
             from(unit in MemoryUnit, where: unit.bank_id == "bank-probe-api", select: unit.id)
             |> Foresight.Repo.all(prefix: target_prefix)
  end

  test "bank migrator converges after directive drift is corrected before source cleanup" do
    suffix = System.unique_integer([:positive])
    source_prefix = "tenant_migrate_directive_recover_source_#{suffix}"
    target_prefix = "tenant_migrate_directive_recover_target_#{suffix}"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_directive} =
      %Directive{}
      |> Directive.changeset(%{
        bank_id: "bank-migrate",
        name: "Stay grounded",
        content: "Answer only from grounded memory",
        priority: 5,
        is_active: true,
        tags: ["migrate"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _target_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _target_directive} =
      %Directive{id: source_directive.id}
      |> Directive.changeset(%{
        bank_id: "bank-migrate",
        name: "Stay grounded",
        content: "Drifted directive content",
        priority: 5,
        is_active: true,
        tags: ["migrate"],
        metadata: %{"scope" => "reflect"}
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-migrate",
               detail: %{
                 clean?: false,
                 source_directive_count: 1,
                 target_directive_count: 1,
                 mismatched_directive_ids: [directive_mismatch_id]
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert directive_mismatch_id == source_directive.id

    assert {1, nil} =
             from(directive in Directive, where: directive.id == ^source_directive.id)
             |> Foresight.Repo.update_all(
               [set: [content: "Answer only from grounded memory"]],
               prefix: target_prefix
             )

    assert {:ok,
            %{
              copy_result: %{
                copied_banks: 0,
                copied_directives: 0,
                copied_file_storage: 0,
                copied_documents: 0,
                copied_memory_units: 0,
                copied_entities: 0,
                copied_memory_unit_entities: 0,
                copied_entity_links: 0
              },
              parity_probe: %{
                clean?: true,
                source_directive_count: 1,
                target_directive_count: 1,
                mismatched_directive_ids: []
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )
  end

  test "bank migrator converges after webhook drift is corrected before source cleanup" do
    suffix = System.unique_integer([:positive])
    source_prefix = "tenant_migrate_webhook_recover_source_#{suffix}"
    target_prefix = "tenant_migrate_webhook_recover_target_#{suffix}"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_webhook} =
      %Foresight.Schemas.Webhook{}
      |> Foresight.Schemas.Webhook.changeset(%{
        bank_id: "bank-migrate",
        url: "https://example.test/hooks/migrate",
        secret: "migrate-secret",
        event_types: ["memory.retained"],
        enabled: true
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _target_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: target_prefix)

    {:ok, _target_webhook} =
      %Foresight.Schemas.Webhook{id: source_webhook.id}
      |> Foresight.Schemas.Webhook.changeset(%{
        bank_id: "bank-migrate",
        url: "https://example.test/hooks/migrate",
        secret: "drifted-secret",
        event_types: ["memory.retained"],
        enabled: true
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-migrate",
               detail: %{
                 clean?: false,
                 source_webhook_count: 1,
                 target_webhook_count: 1,
                 mismatched_webhook_ids: [webhook_mismatch_id]
               }
             }}} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert webhook_mismatch_id == source_webhook.id

    assert {1, nil} =
             from(webhook in Foresight.Schemas.Webhook, where: webhook.id == ^source_webhook.id)
             |> Foresight.Repo.update_all([set: [secret: "migrate-secret"]],
               prefix: target_prefix
             )

    assert {:ok,
            %{
              copy_result: %{
                copied_banks: 0,
                copied_directives: 0,
                copied_webhooks: 0,
                copied_file_storage: 0,
                copied_documents: 0,
                copied_memory_units: 0,
                copied_entities: 0,
                copied_memory_unit_entities: 0,
                copied_entity_links: 0
              },
              parity_probe: %{
                clean?: true,
                source_webhook_count: 1,
                target_webhook_count: 1,
                mismatched_webhook_ids: []
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )
  end

  test "bank migrator intentionally excludes audit log rows from tracked copy and parity" do
    suffix = System.unique_integer([:positive])
    source_prefix = "tenant_migrate_audit_log_source_#{suffix}"
    target_prefix = "tenant_migrate_audit_log_target_#{suffix}"

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-migrate", name: "Migrated Bank", mission: "Migrated mission"})
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _audit_log} =
      %Foresight.Schemas.AuditLog{}
      |> Foresight.Schemas.AuditLog.changeset(%{
        action: "retain",
        transport: "http",
        bank_id: "bank-migrate",
        started_at: ~U[2026-01-01 00:00:00Z],
        ended_at: ~U[2026-01-01 00:00:01Z],
        request: %{"path" => "/v1/default/banks/bank-migrate/memories"},
        response: %{"success" => true},
        metadata: %{"request_id" => "audit-log-migrate"}
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    assert {:ok,
            %{
              migration_policy: %{
                excluded_surfaces: [:audit_log]
              },
              copy_result: %{
                copied_banks: 1,
                copied_directives: 0,
                copied_webhooks: 0,
                copied_file_storage: 0,
                copied_documents: 0,
                copied_memory_units: 0,
                copied_entities: 0,
                copied_memory_unit_entities: 0,
                copied_entity_links: 0
              },
              parity_probe: %{
                clean?: true,
                source_directive_count: 0,
                target_directive_count: 0,
                source_webhook_count: 0,
                target_webhook_count: 0,
                source_file_storage_count: 0,
                target_file_storage_count: 0,
                source_document_count: 0,
                target_document_count: 0,
                source_memory_unit_count: 0,
                target_memory_unit_count: 0,
                source_entity_count: 0,
                target_entity_count: 0,
                source_memory_unit_entity_count: 0,
                target_memory_unit_entity_count: 0,
                source_entity_link_count: 0,
                target_entity_link_count: 0
              }
            }} =
             BankMigrator.migrate(source_prefix, target_prefix, "bank-migrate",
               repo: Foresight.Repo
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM \"#{source_prefix}\".audit_log WHERE bank_id = 'bank-migrate'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM \"#{target_prefix}\".audit_log WHERE bank_id = 'bank-migrate'",
               []
             )
  end

  test "real store queries remain bank-isolated under the migrated schema" do
    ctx_a = %Context{tenant_id: "default", mode: :mode_a, bank: "bank-a"}
    ctx_b = %Context{tenant_id: "default", mode: :mode_a, bank: "bank-b"}

    opts = [
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      queue: Foresight.TestSupport.FakeAsyncQueue
    ]

    assert {:ok, _} =
             EctoStorage.retain(
               ctx_a,
               %{
                 "items" => [%{"content" => "shared topic from a", "context" => "chat"}]
               },
               opts
             )

    assert {:ok, _} =
             EctoStorage.retain(
               ctx_b,
               %{
                 "items" => [%{"content" => "shared topic from b", "context" => "chat"}]
               },
               opts
             )

    assert {:ok,
            %{
              "items" => [%{"content" => "shared topic from a", "type" => "experience"}],
              "total" => 1
            }} = EctoStorage.list_memories(ctx_a, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "items" => [%{"content" => "shared topic from b", "type" => "experience"}],
              "total" => 1
            }} = EctoStorage.list_memories(ctx_b, %{}, repo: Foresight.Repo)
  end

  test "consolidation writes stay inside the tenant prefix schema" do
    prefix = "tenant_acme"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_acme", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    prefixed_ctx = %Context{
      tenant_id: "tenant-acme",
      mode: :mode_a,
      bank: "bank-a",
      prefix: prefix
    }

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-a", name: "Bank A", mission: ""})
      |> Foresight.Repo.insert(prefix: prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-a",
        fact_type: :experience,
        content: "alpha note",
        context: "chat",
        tags: ["alpha"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: prefix)

    assert {:ok,
            %{
              "success" => true,
              "bank_id" => "bank-a",
              "observations_created" => 1,
              "scopes_consolidated" => 1,
              "operation" => "consolidate"
            }} =
             EctoStorage.consolidate(prefixed_ctx, %{},
               repo: Foresight.Repo,
               llm: Foresight.TestSupport.FakeLLM
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_acme.memory_units WHERE fact_type = 'observation'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_acme.documents WHERE external_id = 'mental-model:alpha'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.memory_units WHERE fact_type = 'observation'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.documents WHERE external_id = 'mental-model:alpha'",
               []
             )
  end

  test "retain writes stay inside the tenant prefix schema" do
    prefix = "tenant_retain"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_retain", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    prefixed_ctx = %Context{
      tenant_id: "tenant-retain",
      mode: :mode_a,
      bank: "bank-retain",
      prefix: prefix
    }

    assert {:ok, %{"success" => true, "bank_id" => "bank-retain", "items_count" => 1}} =
             EctoStorage.retain(
               prefixed_ctx,
               %{
                 "items" => [
                   %{
                     "content" => "prefixed retain note",
                     "context" => "chat",
                     "metadata" => %{"document_id" => "doc-retain"}
                   }
                 ]
               },
               repo: Foresight.Repo,
               embedder: Foresight.TestSupport.FakeEmbedder,
               queue: Foresight.TestSupport.FakeAsyncQueue
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(Foresight.Repo, "SELECT count(*) FROM tenant_retain.banks", [])

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_retain.memory_units WHERE content = 'prefixed retain note'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_retain.documents WHERE external_id = 'doc-retain'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.banks WHERE id = 'bank-retain'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.memory_units WHERE content = 'prefixed retain note'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.documents WHERE external_id = 'doc-retain'",
               []
             )
  end

  test "recall reads stay inside the tenant prefix schema" do
    prefix = "tenant_recall"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_recall", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    prefixed_ctx = %Context{
      tenant_id: "tenant-recall",
      mode: :mode_a,
      bank: "bank-recall",
      prefix: prefix
    }

    public_ctx = %Context{
      tenant_id: "default",
      mode: :mode_a,
      bank: "bank-recall"
    }

    opts = [
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      queue: Foresight.TestSupport.FakeAsyncQueue
    ]

    assert {:ok, _} =
             EctoStorage.retain(
               public_ctx,
               %{
                 "items" => [
                   %{
                     "content" => "shared scoped note from public",
                     "context" => "chat"
                   }
                 ]
               },
               opts
             )

    assert {:ok, _} =
             EctoStorage.retain(
               prefixed_ctx,
               %{
                 "items" => [
                   %{
                     "content" => "shared scoped note from tenant",
                     "context" => "chat"
                   }
                 ]
               },
               opts
             )

    assert {:ok, %{"results" => results}} =
             EctoStorage.recall(prefixed_ctx, %{"query" => "shared scoped"}, opts)

    assert Enum.map(results, & &1["text"]) == ["shared scoped note from tenant"]
  end

  test "list and stats reads stay inside the tenant prefix schema" do
    prefix = "tenant_surface"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_surface", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    prefixed_ctx = %Context{
      tenant_id: "tenant-surface",
      mode: :mode_a,
      bank: "bank-surface",
      prefix: prefix
    }

    public_ctx = %Context{
      tenant_id: "default",
      mode: :mode_a,
      bank: "bank-surface"
    }

    opts = [
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      queue: Foresight.TestSupport.FakeAsyncQueue
    ]

    assert {:ok, _} =
             EctoStorage.retain(
               public_ctx,
               %{
                 "items" => [
                   %{
                     "content" => "surface note from public",
                     "context" => "chat",
                     "metadata" => %{"document_id" => "doc-public"}
                   }
                 ]
               },
               opts
             )

    assert {:ok, _} =
             EctoStorage.retain(
               prefixed_ctx,
               %{
                 "items" => [
                   %{
                     "content" => "surface note from tenant",
                     "context" => "chat",
                     "metadata" => %{"document_id" => "doc-tenant"}
                   }
                 ]
               },
               opts
             )

    assert {:ok,
            %{
              "items" => [%{"content" => "surface note from tenant"}],
              "total" => 1
            }} = EctoStorage.list_memories(prefixed_ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "items" => [%{"id" => "doc-tenant"}],
              "total" => 1
            }} = EctoStorage.list_documents(prefixed_ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "bank_id" => "bank-surface",
              "total_nodes" => 1,
              "total_documents" => 1,
              "nodes_by_fact_type" => %{"experience" => 1}
            }} = EctoStorage.bank_stats(prefixed_ctx, "bank-surface", repo: Foresight.Repo)
  end

  test "entity reads stay inside the tenant prefix schema" do
    prefix = "tenant_entities"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_entities", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    prefixed_ctx = %Context{
      tenant_id: "tenant-entities",
      mode: :mode_a,
      bank: "bank-entities",
      prefix: prefix
    }

    public_ctx = %Context{
      tenant_id: "default",
      mode: :mode_a,
      bank: "bank-entities"
    }

    opts = [
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      queue: Foresight.TestSupport.FakeAsyncQueue
    ]

    assert {:ok, _} =
             EctoStorage.retain(
               public_ctx,
               %{
                 "items" => [
                   %{"content" => "Alice met Bob in public", "context" => "chat"}
                 ]
               },
               opts
             )

    assert {:ok, _} =
             EctoStorage.retain(
               prefixed_ctx,
               %{
                 "items" => [
                   %{"content" => "Carol met Dana in tenant", "context" => "chat"}
                 ]
               },
               opts
             )

    assert {:ok,
            %{
              "items" => [
                %{"canonical_name" => "Carol", "mention_count" => 1},
                %{"canonical_name" => "Dana", "mention_count" => 1}
              ],
              "total" => 2
            }} = EctoStorage.list_entities(prefixed_ctx, %{}, repo: Foresight.Repo)
  end

  test "bank admin reads stay inside the tenant prefix schema" do
    prefix = "tenant_banks"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_banks", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    prefixed_ctx = %Context{
      tenant_id: "tenant-banks",
      mode: :mode_a,
      bank: "bank-admin",
      prefix: prefix
    }

    public_ctx = %Context{
      tenant_id: "default",
      mode: :mode_a,
      bank: "bank-admin"
    }

    assert {:ok, %{"bank_id" => "bank-admin", "name" => "Public Bank"}} =
             EctoStorage.put_bank(
               public_ctx,
               "bank-admin",
               %{"name" => "Public Bank", "mission" => "Public mission"},
               repo: Foresight.Repo
             )

    assert {:ok, %{"bank_id" => "bank-admin", "name" => "Tenant Bank"}} =
             EctoStorage.put_bank(
               prefixed_ctx,
               "bank-admin",
               %{"name" => "Tenant Bank", "mission" => "Tenant mission"},
               repo: Foresight.Repo
             )

    assert {:ok, [%{"bank_id" => "bank-admin", "name" => "Tenant Bank"}]} =
             EctoStorage.list_banks(prefixed_ctx, repo: Foresight.Repo)

    assert {:ok,
            %{
              "bank_id" => "bank-admin",
              "name" => "Tenant Bank",
              "mission" => "Tenant mission"
            }} = EctoStorage.bank_profile(prefixed_ctx, "bank-admin", repo: Foresight.Repo)

    assert {:ok, %{"id" => "bank-admin", "deleted" => true, "deleted_count" => 0}} =
             EctoStorage.delete_bank(prefixed_ctx, "bank-admin", repo: Foresight.Repo)

    assert {:ok, []} = EctoStorage.list_banks(prefixed_ctx, repo: Foresight.Repo)

    assert {:ok, public_banks} = EctoStorage.list_banks(public_ctx, repo: Foresight.Repo)

    assert Enum.any?(public_banks, fn bank ->
             bank["bank_id"] == "bank-admin" and bank["name"] == "Public Bank" and
               bank["mission"] == "Public mission"
           end)
  end

  test "queued consolidation worker preserves tenant prefix for writes" do
    prefix = "tenant_worker"
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.TestSupport.FakeLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_worker", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    {:ok, _bank} =
      %Bank{}
      |> Bank.changeset(%{id: "bank-a", name: "Bank A", mission: ""})
      |> Foresight.Repo.insert(prefix: prefix)

    {:ok, _memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-a",
        fact_type: :experience,
        content: "beta note",
        context: "chat",
        tags: ["beta"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: prefix)

    assert :ok =
             ConsolidateWorker.perform(%Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-worker",
                   "mode" => "mode_a",
                   "bank" => "bank-a",
                   "role_name" => nil,
                   "prefix" => prefix,
                   "embedding_dim" => nil
                 },
                 "payload" => %{}
               }
             })

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_worker.memory_units WHERE fact_type = 'observation'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM tenant_worker.documents WHERE external_id = 'mental-model:beta'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.memory_units WHERE fact_type = 'observation'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.documents WHERE external_id = 'mental-model:beta'",
               []
             )
  end

  test "queued migrate_bank worker copies a tenant bank across prefixed schemas" do
    source_prefix = "tenant_migrate_worker_source"
    target_prefix = "tenant_migrate_worker_target"
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-migrate-worker",
        name: "Migrated Bank",
        mission: "Migrated mission"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate-worker",
        data: "worker-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_document} =
      %Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate-worker",
        external_id: "doc-migrate-worker",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate-worker",
        file_storage_key: "file-migrate-worker"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate-worker",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate-worker",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate-worker")

    assert :ok =
             MigrateBankWorker.perform(%Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-migrate-worker",
                   "mode" => "mode_a",
                   "bank" => "bank-migrate-worker",
                   "role_name" => nil,
                   "prefix" => nil,
                   "embedding_dim" => nil
                 },
                 "tenant_scope" => %{
                   "tenant_ids" => ["tenant-migrate-worker"],
                   "roles" => nil,
                   "prefixes" => nil
                 },
                 "payload" => %{
                   "bank_id" => "bank-migrate-worker",
                   "source_prefix" => source_prefix,
                   "target_prefix" => target_prefix
                 }
               }
             })

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{target_prefix}.banks WHERE id = 'bank-migrate-worker'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{target_prefix}.documents WHERE external_id = 'doc-migrate-worker'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{target_prefix}.memory_units WHERE bank_id = 'bank-migrate-worker'",
               []
             )

    assert {:ok, %{rows: [[1]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{target_prefix}.file_storage WHERE storage_key = 'file-migrate-worker'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.banks WHERE id = 'bank-migrate-worker'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.documents WHERE external_id = 'doc-migrate-worker'",
               []
             )

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM public.memory_units WHERE bank_id = 'bank-migrate-worker'",
               []
             )
  end

  test "queued migrate_bank worker persists successful results for operation readback" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    source_prefix = "tenant_migrate_worker_success_source"
    target_prefix = "tenant_migrate_worker_success_target"
    original_engine = Application.get_env(:foresight, :engine)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-migrate-worker-success",
        name: "Migrated Bank",
        mission: "Migrated mission"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_file_storage} =
      %Foresight.Schemas.FileStorage{}
      |> Foresight.Schemas.FileStorage.changeset(%{
        storage_key: "file-migrate-worker-success",
        data: "worker-binary"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_document} =
      %Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate-worker-success",
        external_id: "doc-migrate-worker-success",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate-worker-success",
        file_storage_key: "file-migrate-worker-success"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate-worker-success",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate-worker-success",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    seed_test_embeddings!(source_prefix, "bank-migrate-worker-success")

    ctx = %Context{
      tenant_id: "tenant-migrate-worker-success",
      mode: :mode_a,
      bank: "bank-migrate-worker-success",
      role_name: "reader",
      prefix: "tenant_migrate_worker_success"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-migrate-worker-success",
          "mode" => "mode_a",
          "bank" => "bank-migrate-worker-success",
          "role_name" => "reader",
          "prefix" => "tenant_migrate_worker_success",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-migrate-worker-success"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_migrate_worker_success"]
        },
        "payload" => %{
          "bank_id" => "bank-migrate-worker-success",
          "source_prefix" => source_prefix,
          "target_prefix" => target_prefix,
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "scheduled",
        attempt: 0,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now
      )
      |> Foresight.Repo.insert!()

    assert :ok = MigrateBankWorker.perform(job)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "pending",
              "operation_type" => "migrate_bank",
              "result_stage" => "probe",
              "result_clean" => true,
              "result_excluded_surfaces" => ["audit_log"],
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result_has_probe_drift" => false,
              "result_has_copy_incompleteness" => false,
              "result_copy_counts" => %{
                "copied_banks" => 1,
                "copied_file_storage" => 1,
                "copied_documents" => 1,
                "copied_memory_units" => 1
              },
              "result" => %{
                "bank_id" => "bank-migrate-worker-success",
                "source_prefix" => ^source_prefix,
                "target_prefix" => ^target_prefix,
                "migration_policy" => %{
                  "excluded_surfaces" => ["audit_log"]
                },
                "target_provisioned" => %{
                  "prefix" => ^target_prefix,
                  "migrated_versions" => []
                },
                "copy_result" => %{
                  "copied_banks" => 1,
                  "copied_file_storage" => 1,
                  "copied_documents" => 1,
                  "copied_memory_units" => 1
                },
                "parity_probe" => %{
                  "clean?" => true
                }
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "queued probe_bank worker persists successful results for operation readback" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    source_prefix = "tenant_probe_worker_success_source"
    target_prefix = "tenant_probe_worker_success_target"
    original_engine = Application.get_env(:foresight, :engine)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-probe-worker-success",
        name: "Probe Bank",
        mission: "Probe mission"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-probe-worker-success",
        fact_type: :experience,
        content: "probe note",
        context: "chat",
        tags: ["probe"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _target_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-probe-worker-success",
        name: "Probe Bank",
        mission: "Probe mission"
      })
      |> Foresight.Repo.insert(prefix: target_prefix)

    seed_test_embeddings!(source_prefix, "bank-probe-worker-success")

    assert {:ok, _} =
             SQL.query(
               Foresight.Repo,
               """
               INSERT INTO #{target_prefix}.memory_units
               (id, bank_id, fact_type, content, context, tags, metadata, proof_count, source_memory_ids,
                embedding_384, embedded_by, embedded_dim, mentioned_at, observation_scopes, inserted_at, updated_at)
               SELECT id, bank_id, fact_type, content, context, tags, metadata, proof_count, source_memory_ids,
                      embedding_384, embedded_by, embedded_dim, mentioned_at, observation_scopes, inserted_at, updated_at
               FROM #{source_prefix}.memory_units
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(source_memory.id)]
             )

    ctx = %Context{
      tenant_id: "tenant-probe-worker-success",
      mode: :mode_a,
      bank: "bank-probe-worker-success",
      role_name: "reader",
      prefix: "tenant_probe_worker_success"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-probe-worker-success",
          "mode" => "mode_a",
          "bank" => "bank-probe-worker-success",
          "role_name" => "reader",
          "prefix" => "tenant_probe_worker_success",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-probe-worker-success"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_probe_worker_success"]
        },
        "payload" => %{
          "bank_id" => "bank-probe-worker-success",
          "source_prefix" => source_prefix,
          "target_prefix" => target_prefix,
          "async" => false
        }
      }
      |> Job.new(
        worker: ProbeBankWorker,
        queue: "foresight_probe_bank",
        state: "scheduled",
        attempt: 0,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now
      )
      |> Foresight.Repo.insert!()

    assert :ok = ProbeBankWorker.perform(job)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "pending",
              "operation_type" => "probe_bank_migration",
              "result_stage" => "probe",
              "result_clean" => true,
              "result_excluded_surfaces" => ["audit_log"],
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result_has_probe_drift" => false,
              "result_probe_counts" => %{
                "source_memory_unit_count" => 1,
                "target_memory_unit_count" => 1
              },
              "result" => %{
                "bank_id" => "bank-probe-worker-success",
                "source_prefix" => ^source_prefix,
                "target_prefix" => ^target_prefix,
                "migration_policy" => %{
                  "excluded_surfaces" => ["audit_log"]
                },
                "target_provisioned" => %{
                  "prefix" => ^target_prefix,
                  "migrated_versions" => []
                },
                "source_audit" => %{
                  "compatible?" => true
                },
                "parity_probe" => %{
                  "clean?" => true,
                  "source_memory_unit_count" => 1,
                  "target_memory_unit_count" => 1
                }
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "queued probe_bank worker persists failure diagnostics for operation readback" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    source_prefix = "tenant_probe_worker_fail_source"
    target_prefix = "tenant_probe_worker_fail_target"
    original_engine = Application.get_env(:foresight, :engine)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-probe-worker-fail",
        name: "Probe Bank",
        mission: "Probe mission"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-probe-worker-fail",
        fact_type: :experience,
        content: "probe note",
        context: "chat",
        tags: ["probe"],
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    ctx = %Context{
      tenant_id: "tenant-probe-worker-fail",
      mode: :mode_a,
      bank: "bank-probe-worker-fail",
      role_name: "reader",
      prefix: "tenant_probe_worker_fail"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-probe-worker-fail",
          "mode" => "mode_a",
          "bank" => "bank-probe-worker-fail",
          "role_name" => "reader",
          "prefix" => "tenant_probe_worker_fail",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-probe-worker-fail"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_probe_worker_fail"]
        },
        "payload" => %{
          "bank_id" => "bank-probe-worker-fail",
          "source_prefix" => source_prefix,
          "target_prefix" => target_prefix,
          "async" => false
        }
      }
      |> Job.new(
        worker: ProbeBankWorker,
        queue: "foresight_probe_bank",
        state: "available",
        attempt: 0,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now
      )
      |> Foresight.Repo.insert!()

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :probe,
               failure_kind: :parity_probe_failed,
               bank_id: "bank-probe-worker-fail",
               detail: %{
                 clean?: false,
                 source_memory_unit_count: 1,
                 target_memory_unit_count: 0
               }
             }}} = ProbeBankWorker.perform(job)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "pending",
              "operation_type" => "probe_bank_migration",
              "result_diagnostic_type" => "migration_diagnostics",
              "result_stage" => "probe",
              "result_failure_kind" => "parity_probe_failed",
              "result_excluded_surfaces" => ["audit_log"],
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result_has_probe_drift" => true,
              "result" => %{
                "diagnostic_type" => "migration_diagnostics",
                "stage" => "probe",
                "failure_kind" => "parity_probe_failed",
                "bank_id" => "bank-probe-worker-fail",
                "source_prefix" => ^source_prefix,
                "target_prefix" => ^target_prefix,
                "migration_policy" => %{"excluded_surfaces" => ["audit_log"]},
                "detail" => %{
                  "clean?" => false,
                  "source_memory_unit_count" => 1,
                  "target_memory_unit_count" => 0
                }
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "queued migrate_bank worker persists failure diagnostics for operation readback" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    source_prefix = "tenant_migrate_worker_fail_source"
    target_prefix = "tenant_migrate_worker_fail_target"
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-migrate-worker-fail",
        name: "Migrated Bank",
        mission: "Migrated mission"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_document} =
      %Document{}
      |> Document.changeset(%{
        bank_id: "bank-migrate-worker-fail",
        external_id: "doc-migrate-worker-fail",
        title: "Migrated Doc",
        original_text: "migrated source text",
        content_hash: "hash-migrate-worker-fail",
        file_storage_key: "file-migrate-worker-fail"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate-worker-fail",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        document_ref: "doc-migrate-worker-fail",
        embedded_by: "test",
        embedded_dim: 384,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-migrate-worker-fail",
      mode: :mode_a,
      bank: "bank-migrate-worker-fail",
      role_name: "reader",
      prefix: "tenant_migrate_worker_fail"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-migrate-worker-fail",
          "mode" => "mode_a",
          "bank" => "bank-migrate-worker-fail",
          "role_name" => "reader",
          "prefix" => "tenant_migrate_worker_fail",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-migrate-worker-fail"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_migrate_worker_fail"]
        },
        "payload" => %{
          "bank_id" => "bank-migrate-worker-fail",
          "source_prefix" => source_prefix,
          "target_prefix" => target_prefix,
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "available",
        attempt: 0,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now
      )
      |> Foresight.Repo.insert!()

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :copy,
               failure_kind: :incomplete_dependent_rows,
               bank_id: "bank-migrate-worker-fail",
               detail: %{
                 dependency: :file_storage
               }
             }}} = MigrateBankWorker.perform(job)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "pending",
              "operation_type" => "migrate_bank",
              "result_diagnostic_type" => "migration_diagnostics",
              "result_stage" => "copy",
              "result_failure_kind" => "incomplete_dependent_rows",
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result_copy_dependency" => "file_storage",
              "result_copy_total_rows" => 1,
              "result_copy_blocked_rows" => 1,
              "result_has_copy_incompleteness" => true,
              "result" => %{
                "diagnostic_type" => "migration_diagnostics",
                "stage" => "copy",
                "failure_kind" => "incomplete_dependent_rows",
                "bank_id" => "bank-migrate-worker-fail",
                "source_prefix" => ^source_prefix,
                "target_prefix" => ^target_prefix,
                "detail" => %{
                  "dependency" => "file_storage"
                }
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{target_prefix}.banks WHERE id = 'bank-migrate-worker-fail'",
               []
             )
  end

  test "queued migrate_bank worker persists audit-stage diagnostics for incompatible source audit" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    source_prefix = "tenant_migrate_worker_audit_fail_source"
    target_prefix = "tenant_migrate_worker_audit_fail_target"
    original_engine = Application.get_env(:foresight, :engine)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    Application.put_env(:foresight, :engine,
      storage: EctoStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, _} = SchemaProvisioner.provision(source_prefix, repo: Foresight.Repo)
    assert {:ok, _} = SchemaProvisioner.provision(target_prefix, repo: Foresight.Repo)

    {:ok, _source_bank} =
      %Bank{}
      |> Bank.changeset(%{
        id: "bank-migrate-worker-audit-fail",
        name: "Migrated Bank",
        mission: "Migrated mission"
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    {:ok, _source_memory} =
      %MemoryUnit{}
      |> MemoryUnit.changeset(%{
        bank_id: "bank-migrate-worker-audit-fail",
        fact_type: :experience,
        content: "migrated note",
        context: "chat",
        tags: ["migrate"],
        embedded_by: "test",
        embedded_dim: 4096,
        mentioned_at: ~U[2026-01-01 00:00:00Z]
      })
      |> Foresight.Repo.insert(prefix: source_prefix)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-migrate-worker-audit-fail",
      mode: :mode_a,
      bank: "bank-migrate-worker-audit-fail",
      role_name: "reader",
      prefix: "tenant_migrate_worker_audit_fail"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-migrate-worker-audit-fail",
          "mode" => "mode_a",
          "bank" => "bank-migrate-worker-audit-fail",
          "role_name" => "reader",
          "prefix" => "tenant_migrate_worker_audit_fail",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-migrate-worker-audit-fail"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_migrate_worker_audit_fail"]
        },
        "payload" => %{
          "bank_id" => "bank-migrate-worker-audit-fail",
          "source_prefix" => source_prefix,
          "target_prefix" => target_prefix,
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "available",
        attempt: 0,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now
      )
      |> Foresight.Repo.insert!()

    assert {:error,
            {:migration_diagnostics,
             %{
               stage: :audit,
               failure_kind: :incompatible_source_audit,
               bank_id: "bank-migrate-worker-audit-fail",
               source_audit: %{
                 compatible?: false,
                 embedded_dims: [4096],
                 embedding_columns: [384, 1024, 1536, 3072]
               }
             }}} = MigrateBankWorker.perform(job)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "pending",
              "operation_type" => "migrate_bank",
              "result_diagnostic_type" => "migration_diagnostics",
              "result_stage" => "audit",
              "result_failure_kind" => "incompatible_source_audit",
              "result_excluded_surfaces" => ["audit_log"],
              "result_source_compatible" => false,
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result" => %{
                "diagnostic_type" => "migration_diagnostics",
                "stage" => "audit",
                "failure_kind" => "incompatible_source_audit",
                "bank_id" => "bank-migrate-worker-audit-fail",
                "source_prefix" => ^source_prefix,
                "target_prefix" => ^target_prefix,
                "migration_policy" => %{"excluded_surfaces" => ["audit_log"]},
                "source_audit" => %{
                  "compatible?" => false,
                  "embedded_dims" => [4096],
                  "embedding_columns" => [384, 1024, 1536, 3072]
                }
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)

    assert {:ok, %{rows: [[0]]}} =
             SQL.query(
               Foresight.Repo,
               "SELECT count(*) FROM #{target_prefix}.banks WHERE id = 'bank-migrate-worker-audit-fail'",
               []
             )
  end

  test "real Oban operation detail exposes persisted migrate_bank result payload" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-op",
      mode: :mode_a,
      bank: "bank-op",
      role_name: "reader",
      prefix: "tenant_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-op",
          "mode" => "mode_a",
          "bank" => "bank-op",
          "role_name" => "reader",
          "prefix" => "tenant_op",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-op"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_op"]
        },
        "payload" => %{
          "bank_id" => "bank-op",
          "source_prefix" => "tenant_source",
          "target_prefix" => "tenant_target",
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "completed",
        attempt: 1,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        completed_at: now,
        meta: %{
          "operation_result" => %{
            "bank_id" => "bank-op",
            "source_prefix" => "tenant_source",
            "target_prefix" => "tenant_target",
            "migration_policy" => %{
              "excluded_surfaces" => ["audit_log"]
            },
            "target_provisioned" => %{
              "prefix" => "tenant_target",
              "migrated_versions" => [20_260_601_162_000]
            },
            "copy_result" => %{"copied_banks" => 1},
            "parity_probe" => %{"clean?" => true}
          }
        }
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "migrate_bank",
                  "status" => "completed",
                  "result_stage" => "probe",
                  "result_clean" => true,
                  "result_excluded_surfaces" => ["audit_log"],
                  "result_target_provisioned" => true,
                  "result_target_migrated_version_count" => 1,
                  "result_has_probe_drift" => false,
                  "result_has_copy_incompleteness" => false,
                  "result_copy_counts" => %{"copied_banks" => 1}
                }
              ]
            }} = ObanQueue.list_operations(ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "completed",
              "operation_type" => "migrate_bank",
              "result_stage" => "probe",
              "result_clean" => true,
              "result_excluded_surfaces" => ["audit_log"],
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 1,
              "result_has_probe_drift" => false,
              "result_has_copy_incompleteness" => false,
              "result_copy_counts" => %{
                "copied_banks" => 1
              },
              "result" => %{
                "bank_id" => "bank-op",
                "source_prefix" => "tenant_source",
                "target_prefix" => "tenant_target",
                "migration_policy" => %{
                  "excluded_surfaces" => ["audit_log"]
                },
                "target_provisioned" => %{
                  "prefix" => "tenant_target",
                  "migrated_versions" => [20_260_601_162_000]
                },
                "copy_result" => %{"copied_banks" => 1},
                "parity_probe" => %{"clean?" => true}
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "real Oban operation detail exposes persisted migrate_bank failure diagnostics" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-op-fail",
      mode: :mode_a,
      bank: "bank-op-fail",
      role_name: "reader",
      prefix: "tenant_op_fail"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-op-fail",
          "mode" => "mode_a",
          "bank" => "bank-op-fail",
          "role_name" => "reader",
          "prefix" => "tenant_op_fail",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-op-fail"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_op_fail"]
        },
        "payload" => %{
          "bank_id" => "bank-op-fail",
          "source_prefix" => "tenant_source_fail",
          "target_prefix" => "tenant_target_fail",
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "discarded",
        attempt: 1,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        discarded_at: now,
        errors: [%{"attempt" => 1, "at" => DateTime.to_iso8601(now), "error" => "probe failed"}],
        meta: %{
          "operation_result" => %{
            "diagnostic_type" => "migration_diagnostics",
            "stage" => "probe",
            "failure_kind" => "parity_probe_failed",
            "bank_id" => "bank-op-fail",
            "source_prefix" => "tenant_source_fail",
            "target_prefix" => "tenant_target_fail",
            "migration_policy" => %{
              "excluded_surfaces" => ["audit_log"]
            },
            "target_provisioned" => %{
              "prefix" => "tenant_target_fail",
              "migrated_versions" => []
            },
            "detail" => %{
              "parity_probe" => %{
                "clean?" => false,
                "mismatched_memory_unit_ids" => ["mu-op-fail"]
              }
            }
          }
        }
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "migrate_bank",
                  "status" => "failed",
                  "error_message" => "probe failed",
                  "result_diagnostic_type" => "migration_diagnostics",
                  "result_stage" => "probe",
                  "result_failure_kind" => "parity_probe_failed",
                  "result_excluded_surfaces" => ["audit_log"],
                  "result_target_provisioned" => true,
                  "result_target_migrated_version_count" => 0,
                  "result_has_probe_drift" => true,
                  "result_probe_mismatch_counts" => %{"mismatched_memory_unit_ids" => 1}
                }
              ]
            }} = ObanQueue.list_operations(ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "failed",
              "operation_type" => "migrate_bank",
              "error_message" => "probe failed",
              "result_diagnostic_type" => "migration_diagnostics",
              "result_stage" => "probe",
              "result_failure_kind" => "parity_probe_failed",
              "result_excluded_surfaces" => ["audit_log"],
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result_has_probe_drift" => true,
              "result_probe_mismatch_counts" => %{
                "mismatched_memory_unit_ids" => 1
              },
              "result" => %{
                "diagnostic_type" => "migration_diagnostics",
                "stage" => "probe",
                "failure_kind" => "parity_probe_failed",
                "bank_id" => "bank-op-fail",
                "source_prefix" => "tenant_source_fail",
                "target_prefix" => "tenant_target_fail",
                "migration_policy" => %{
                  "excluded_surfaces" => ["audit_log"]
                },
                "target_provisioned" => %{
                  "prefix" => "tenant_target_fail",
                  "migrated_versions" => []
                },
                "detail" => %{
                  "parity_probe" => %{
                    "clean?" => false,
                    "mismatched_memory_unit_ids" => ["mu-op-fail"]
                  }
                }
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "real Oban operation detail exposes persisted consolidate result payload" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-consolidate-op",
      mode: :mode_a,
      bank: "bank-consolidate-op",
      role_name: "reader",
      prefix: "tenant_consolidate_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-consolidate-op",
          "mode" => "mode_a",
          "bank" => "bank-consolidate-op",
          "role_name" => "reader",
          "prefix" => "tenant_consolidate_op",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-consolidate-op"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_consolidate_op"]
        },
        "payload" => %{
          "async" => false,
          "tag_scopes" => [%{"tags" => ["user:alice"]}]
        }
      }
      |> Job.new(
        worker: ConsolidateWorker,
        queue: "foresight_consolidate",
        state: "completed",
        attempt: 1,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        completed_at: now,
        meta: %{
          "operation_result" => %{
            "success" => true,
            "bank_id" => "bank-consolidate-op",
            "observations_created" => 2,
            "scopes_consolidated" => 1,
            "operation" => "consolidate"
          }
        }
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "consolidate",
                  "status" => "completed",
                  "result_operation" => "consolidate",
                  "result_observations_created" => 2,
                  "result_scopes_consolidated" => 1
                }
              ]
            }} = ObanQueue.list_operations(ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "completed",
              "operation_type" => "consolidate",
              "result_operation" => "consolidate",
              "result_observations_created" => 2,
              "result_scopes_consolidated" => 1,
              "result" => %{
                "success" => true,
                "bank_id" => "bank-consolidate-op",
                "observations_created" => 2,
                "scopes_consolidated" => 1,
                "operation" => "consolidate"
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "real Oban operation detail exposes persisted retain result payload" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-retain-op",
      mode: :mode_a,
      bank: "bank-retain-op",
      role_name: "reader",
      prefix: "tenant_retain_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-retain-op",
          "mode" => "mode_a",
          "bank" => "bank-retain-op",
          "role_name" => "reader",
          "prefix" => "tenant_retain_op",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-retain-op"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_retain_op"]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "completed",
        attempt: 1,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        completed_at: now,
        meta: %{
          "operation_result" => %{
            "success" => true,
            "bank_id" => "bank-retain-op",
            "items_count" => 1,
            "async" => false,
            "usage" => nil
          }
        }
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "retain",
                  "status" => "completed",
                  "result_items_count" => 1
                }
              ]
            }} = ObanQueue.list_operations(ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "operation_id" => operation_id,
              "status" => "completed",
              "operation_type" => "retain",
              "result_items_count" => 1,
              "result" => %{
                "success" => true,
                "bank_id" => "bank-retain-op",
                "items_count" => 1,
                "async" => false,
                "usage" => nil
              }
            }} = ObanQueue.get_operation(ctx, Integer.to_string(job.id), repo: Foresight.Repo)

    assert operation_id == Integer.to_string(job.id)
  end

  test "real Oban retryable retain operation stays pending with next_retry_at" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    attempted_at = DateTime.add(inserted_at, 5, :second)
    scheduled_at = DateTime.add(attempted_at, 60, :second)

    ctx = %Context{
      tenant_id: "tenant-retryable-op",
      mode: :mode_a,
      bank: "bank-retryable-op",
      role_name: "reader",
      prefix: "tenant_retryable_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-retryable-op",
          "mode" => "mode_a",
          "bank" => "bank-retryable-op",
          "role_name" => "reader",
          "prefix" => "tenant_retryable_op",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-retryable-op"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_retryable_op"]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "retryable",
        attempt: 2,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: scheduled_at,
        attempted_at: attempted_at,
        errors: [
          %{
            "attempt" => 1,
            "at" => DateTime.to_iso8601(attempted_at),
            "error" => "transient retain failure"
          }
        ]
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "retain",
                  "status" => "pending",
                  "error_message" => "transient retain failure",
                  "retry_count" => 1,
                  "next_retry_at" => summary_retry_at
                }
              ]
            }} = ObanQueue.list_operations(ctx, %{}, repo: Foresight.Repo)

    assert {:ok, parsed_summary_retry_at, 0} = DateTime.from_iso8601(summary_retry_at)
    assert DateTime.compare(parsed_summary_retry_at, scheduled_at) == :eq

    assert {:ok,
            %{
              "operation_id" => ^expected_id,
              "status" => "pending",
              "operation_type" => "retain",
              "completed_at" => nil,
              "error_message" => "transient retain failure",
              "retry_count" => 1,
              "next_retry_at" => detail_retry_at,
              "task_payload" => %{
                "async" => false,
                "items" => [%{"content" => "queued memory", "context" => "chat"}]
              }
            }} = ObanQueue.get_operation(ctx, expected_id, repo: Foresight.Repo)

    assert {:ok, parsed_detail_retry_at, 0} = DateTime.from_iso8601(detail_retry_at)
    assert DateTime.compare(parsed_detail_retry_at, scheduled_at) == :eq
  end

  test "real Oban cancelled retain operation stays cancelled without retry schedule" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    attempted_at = DateTime.add(inserted_at, 5, :second)
    cancelled_at = DateTime.add(attempted_at, 30, :second)

    ctx = %Context{
      tenant_id: "tenant-cancelled-op",
      mode: :mode_a,
      bank: "bank-cancelled-op",
      role_name: "reader",
      prefix: "tenant_cancelled_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-cancelled-op",
          "mode" => "mode_a",
          "bank" => "bank-cancelled-op",
          "role_name" => "reader",
          "prefix" => "tenant_cancelled_op",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-cancelled-op"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_cancelled_op"]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "cancelled",
        attempt: 1,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: inserted_at,
        attempted_at: attempted_at,
        cancelled_at: cancelled_at
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "retain",
                  "status" => "cancelled",
                  "error_message" => nil,
                  "retry_count" => 0,
                  "next_retry_at" => nil
                }
              ]
            }} = ObanQueue.list_operations(ctx, %{}, repo: Foresight.Repo)

    assert {:ok,
            %{
              "operation_id" => ^expected_id,
              "status" => "cancelled",
              "operation_type" => "retain",
              "completed_at" => nil,
              "updated_at" => detail_updated_at,
              "error_message" => nil,
              "retry_count" => 0,
              "next_retry_at" => nil,
              "task_payload" => %{
                "async" => false,
                "items" => [%{"content" => "queued memory", "context" => "chat"}]
              }
            }} = ObanQueue.get_operation(ctx, expected_id, repo: Foresight.Repo)

    assert {:ok, parsed_detail_updated_at, 0} = DateTime.from_iso8601(detail_updated_at)
    assert DateTime.compare(parsed_detail_updated_at, cancelled_at) == :eq
  end

  test "store-backed operation APIs preserve cancelled retain semantics" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    attempted_at = DateTime.add(inserted_at, 5, :second)
    cancelled_at = DateTime.add(attempted_at, 30, :second)

    ctx = %Context{
      tenant_id: "tenant-cancelled-store-op",
      mode: :mode_a,
      bank: "bank-cancelled-store-op",
      role_name: "reader",
      prefix: "tenant_cancelled_store_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-cancelled-store-op",
          "mode" => "mode_a",
          "bank" => "bank-cancelled-store-op",
          "role_name" => "reader",
          "prefix" => "tenant_cancelled_store_op",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-cancelled-store-op"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_cancelled_store_op"]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "cancelled",
        attempt: 1,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: inserted_at,
        attempted_at: attempted_at,
        cancelled_at: cancelled_at
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "retain",
                  "status" => "cancelled",
                  "error_message" => nil,
                  "retry_count" => 0,
                  "next_retry_at" => nil
                }
              ]
            }} = Foresight.list_operations(ctx)

    assert {:ok,
            %{
              "operation_id" => ^expected_id,
              "status" => "cancelled",
              "operation_type" => "retain",
              "completed_at" => nil,
              "updated_at" => detail_updated_at,
              "error_message" => nil,
              "retry_count" => 0,
              "next_retry_at" => nil,
              "task_payload" => %{
                "async" => false,
                "items" => [%{"content" => "queued memory", "context" => "chat"}]
              }
            }} = Foresight.get_operation(ctx, expected_id)

    assert {:ok, parsed_detail_updated_at, 0} = DateTime.from_iso8601(detail_updated_at)
    assert DateTime.compare(parsed_detail_updated_at, cancelled_at) == :eq
  end

  test "store-backed operation APIs preserve retryable retain semantics" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    attempted_at = DateTime.add(inserted_at, 5, :second)
    scheduled_at = DateTime.add(attempted_at, 60, :second)

    ctx = %Context{
      tenant_id: "tenant-retryable-store-op",
      mode: :mode_a,
      bank: "bank-retryable-store-op",
      role_name: "reader",
      prefix: "tenant_retryable_store_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => ctx.tenant_id,
          "mode" => "mode_a",
          "bank" => ctx.bank,
          "role_name" => ctx.role_name,
          "prefix" => ctx.prefix,
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => [ctx.tenant_id],
          "roles" => [ctx.role_name],
          "prefixes" => [ctx.prefix]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "retryable",
        attempt: 2,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: scheduled_at,
        attempted_at: attempted_at,
        errors: [
          %{
            "attempt" => 1,
            "at" => DateTime.to_iso8601(attempted_at),
            "error" => "transient retain failure"
          }
        ]
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "retain",
                  "status" => "pending",
                  "error_message" => "transient retain failure",
                  "retry_count" => 1,
                  "next_retry_at" => summary_retry_at
                }
              ]
            }} = Foresight.list_operations(ctx)

    assert {:ok, parsed_summary_retry_at, 0} = DateTime.from_iso8601(summary_retry_at)
    assert DateTime.compare(parsed_summary_retry_at, scheduled_at) == :eq

    assert {:ok,
            %{
              "operation_id" => ^expected_id,
              "status" => "pending",
              "operation_type" => "retain",
              "completed_at" => nil,
              "error_message" => "transient retain failure",
              "retry_count" => 1,
              "next_retry_at" => detail_retry_at,
              "task_payload" => %{
                "async" => false,
                "items" => [%{"content" => "queued memory", "context" => "chat"}]
              }
            }} = Foresight.get_operation(ctx, expected_id)

    assert {:ok, parsed_detail_retry_at, 0} = DateTime.from_iso8601(detail_retry_at)
    assert DateTime.compare(parsed_detail_retry_at, scheduled_at) == :eq
  end

  test "store-backed operation APIs preserve discarded migration failure semantics" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-op-fail-store",
      mode: :mode_a,
      bank: "bank-op-fail-store",
      role_name: "reader",
      prefix: "tenant_op_fail_store"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => "tenant-op-fail-store",
          "mode" => "mode_a",
          "bank" => "bank-op-fail-store",
          "role_name" => "reader",
          "prefix" => "tenant_op_fail_store",
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => ["tenant-op-fail-store"],
          "roles" => ["reader"],
          "prefixes" => ["tenant_op_fail_store"]
        },
        "payload" => %{
          "bank_id" => "bank-op-fail-store",
          "source_prefix" => "tenant_source_fail",
          "target_prefix" => "tenant_target_fail",
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "discarded",
        attempt: 1,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        discarded_at: now,
        errors: [%{"attempt" => 1, "at" => DateTime.to_iso8601(now), "error" => "probe failed"}],
        meta: %{
          "operation_result" => %{
            "diagnostic_type" => "migration_diagnostics",
            "stage" => "probe",
            "failure_kind" => "parity_probe_failed",
            "bank_id" => "bank-op-fail-store",
            "source_prefix" => "tenant_source_fail",
            "target_prefix" => "tenant_target_fail",
            "migration_policy" => %{
              "excluded_surfaces" => ["audit_log"]
            },
            "target_provisioned" => %{
              "prefix" => "tenant_target_fail",
              "migrated_versions" => []
            },
            "detail" => %{
              "parity_probe" => %{
                "clean?" => false,
                "mismatched_memory_unit_ids" => ["mu-op-fail"]
              }
            }
          }
        }
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    assert {:ok,
            %{
              "operations" => [
                %{
                  "id" => ^expected_id,
                  "task_type" => "migrate_bank",
                  "status" => "failed",
                  "error_message" => "probe failed",
                  "retry_count" => 1,
                  "next_retry_at" => nil,
                  "result_diagnostic_type" => "migration_diagnostics",
                  "result_stage" => "probe",
                  "result_failure_kind" => "parity_probe_failed",
                  "result_excluded_surfaces" => ["audit_log"],
                  "result_has_probe_drift" => true,
                  "result_target_provisioned" => true,
                  "result_target_migrated_version_count" => 0
                }
              ]
            }} = Foresight.list_operations(ctx)

    assert {:ok,
            %{
              "operation_id" => ^expected_id,
              "status" => "failed",
              "operation_type" => "migrate_bank",
              "error_message" => "probe failed",
              "retry_count" => 1,
              "next_retry_at" => nil,
              "result_diagnostic_type" => "migration_diagnostics",
              "result_stage" => "probe",
              "result_failure_kind" => "parity_probe_failed",
              "result_excluded_surfaces" => ["audit_log"],
              "result_has_probe_drift" => true,
              "result_target_provisioned" => true,
              "result_target_migrated_version_count" => 0,
              "result" => %{
                "diagnostic_type" => "migration_diagnostics",
                "stage" => "probe",
                "failure_kind" => "parity_probe_failed",
                "bank_id" => "bank-op-fail-store",
                "source_prefix" => "tenant_source_fail",
                "target_prefix" => "tenant_target_fail",
                "migration_policy" => %{"excluded_surfaces" => ["audit_log"]},
                "target_provisioned" => %{
                  "prefix" => "tenant_target_fail",
                  "migrated_versions" => []
                },
                "detail" => %{
                  "parity_probe" => %{
                    "clean?" => false,
                    "mismatched_memory_unit_ids" => ["mu-op-fail"]
                  }
                }
              }
            }} = Foresight.get_operation(ctx, expected_id)
  end

  test "HTTP operations surface preserves cancelled retain semantics over real store" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    attempted_at = DateTime.add(inserted_at, 5, :second)
    cancelled_at = DateTime.add(attempted_at, 30, :second)

    ctx = %Context{
      tenant_id: "tenant-cancelled-http-op",
      mode: :mode_a,
      bank: "bank-cancelled-http-op",
      role_name: "reader",
      prefix: "tenant_cancelled_http_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => ctx.tenant_id,
          "mode" => "mode_a",
          "bank" => ctx.bank,
          "role_name" => ctx.role_name,
          "prefix" => ctx.prefix,
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => [ctx.tenant_id],
          "roles" => [ctx.role_name],
          "prefixes" => [ctx.prefix]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "cancelled",
        attempt: 1,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: inserted_at,
        attempted_at: attempted_at,
        cancelled_at: cancelled_at
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)
    expected_bank_id = ctx.bank

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    router_config = %{
      auth: %{
        api_key: "secret",
        tenant_scopes: %{
          "secret" => %{
            tenant_ids: [ctx.tenant_id],
            roles: [ctx.role_name],
            prefixes: [ctx.prefix]
          }
        }
      },
      http: %{enabled: true},
      health: %{checker: Foresight.Health},
      ml: %{enabled: false},
      oban: %{enabled: false},
      repo: %{enabled: false}
    }

    list_conn =
      conn(:get, "/v1/default/banks/#{ctx.bank}/operations?limit=10&offset=0")
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("x-foresight-tenant-id", ctx.tenant_id)
      |> put_req_header("x-foresight-role", ctx.role_name)
      |> put_req_header("x-foresight-prefix", ctx.prefix)
      |> Router.call(Router.init(config: router_config))

    assert list_conn.status == 200

    assert %{
             "bank_id" => ^expected_bank_id,
             "operations" => [
               %{
                 "id" => ^expected_id,
                 "task_type" => "retain",
                 "status" => "cancelled",
                 "error_message" => nil,
                 "retry_count" => 0,
                 "next_retry_at" => nil
               }
             ]
           } = Jason.decode!(list_conn.resp_body)

    detail_conn =
      conn(:get, "/v1/default/banks/#{ctx.bank}/operations/#{expected_id}")
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("x-foresight-tenant-id", ctx.tenant_id)
      |> put_req_header("x-foresight-role", ctx.role_name)
      |> put_req_header("x-foresight-prefix", ctx.prefix)
      |> Router.call(Router.init(config: router_config))

    assert detail_conn.status == 200

    assert %{
             "operation_id" => ^expected_id,
             "status" => "cancelled",
             "operation_type" => "retain",
             "completed_at" => nil,
             "error_message" => nil,
             "retry_count" => 0,
             "next_retry_at" => nil,
             "task_payload" => %{
               "async" => false,
               "items" => [%{"content" => "queued memory", "context" => "chat"}]
             }
           } = Jason.decode!(detail_conn.resp_body)
  end

  test "HTTP operations surface preserves retryable retain semantics over real store" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    inserted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    attempted_at = DateTime.add(inserted_at, 5, :second)
    scheduled_at = DateTime.add(attempted_at, 60, :second)

    ctx = %Context{
      tenant_id: "tenant-retryable-http-op",
      mode: :mode_a,
      bank: "bank-retryable-http-op",
      role_name: "reader",
      prefix: "tenant_retryable_http_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => ctx.tenant_id,
          "mode" => "mode_a",
          "bank" => ctx.bank,
          "role_name" => ctx.role_name,
          "prefix" => ctx.prefix,
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => [ctx.tenant_id],
          "roles" => [ctx.role_name],
          "prefixes" => [ctx.prefix]
        },
        "payload" => %{
          "async" => false,
          "items" => [%{"content" => "queued memory", "context" => "chat"}]
        }
      }
      |> Job.new(
        worker: RetainWorker,
        queue: "foresight_retain",
        state: "retryable",
        attempt: 2,
        max_attempts: 5,
        inserted_at: inserted_at,
        scheduled_at: scheduled_at,
        attempted_at: attempted_at,
        errors: [
          %{
            "attempt" => 1,
            "at" => DateTime.to_iso8601(attempted_at),
            "error" => "transient retain failure"
          }
        ]
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)
    expected_bank_id = ctx.bank

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    router_config = %{
      auth: %{
        api_key: "secret",
        tenant_scopes: %{
          "secret" => %{
            tenant_ids: [ctx.tenant_id],
            roles: [ctx.role_name],
            prefixes: [ctx.prefix]
          }
        }
      },
      http: %{enabled: true},
      health: %{checker: Foresight.Health},
      ml: %{enabled: false},
      oban: %{enabled: false},
      repo: %{enabled: false}
    }

    list_conn =
      conn(:get, "/v1/default/banks/#{ctx.bank}/operations?limit=10&offset=0")
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("x-foresight-tenant-id", ctx.tenant_id)
      |> put_req_header("x-foresight-role", ctx.role_name)
      |> put_req_header("x-foresight-prefix", ctx.prefix)
      |> Router.call(Router.init(config: router_config))

    assert list_conn.status == 200

    assert %{
             "bank_id" => ^expected_bank_id,
             "operations" => [
               %{
                 "id" => ^expected_id,
                 "task_type" => "retain",
                 "status" => "pending",
                 "error_message" => "transient retain failure",
                 "retry_count" => 1,
                 "next_retry_at" => summary_retry_at
               }
             ]
           } = Jason.decode!(list_conn.resp_body)

    assert {:ok, parsed_summary_retry_at, 0} = DateTime.from_iso8601(summary_retry_at)
    assert DateTime.compare(parsed_summary_retry_at, scheduled_at) == :eq

    detail_conn =
      conn(:get, "/v1/default/banks/#{ctx.bank}/operations/#{expected_id}")
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("x-foresight-tenant-id", ctx.tenant_id)
      |> put_req_header("x-foresight-role", ctx.role_name)
      |> put_req_header("x-foresight-prefix", ctx.prefix)
      |> Router.call(Router.init(config: router_config))

    assert detail_conn.status == 200

    assert %{
             "operation_id" => ^expected_id,
             "status" => "pending",
             "operation_type" => "retain",
             "completed_at" => nil,
             "error_message" => "transient retain failure",
             "retry_count" => 1,
             "next_retry_at" => detail_retry_at,
             "task_payload" => %{
               "async" => false,
               "items" => [%{"content" => "queued memory", "context" => "chat"}]
             }
           } = Jason.decode!(detail_conn.resp_body)

    assert {:ok, parsed_detail_retry_at, 0} = DateTime.from_iso8601(detail_retry_at)
    assert DateTime.compare(parsed_detail_retry_at, scheduled_at) == :eq
  end

  test "HTTP operations surface preserves discarded migration failure semantics over real store" do
    create_oban_jobs_table!()

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      tenant_id: "tenant-discarded-http-op",
      mode: :mode_a,
      bank: "bank-discarded-http-op",
      role_name: "reader",
      prefix: "tenant_discarded_http_op"
    }

    job =
      %{
        "context" => %{
          "tenant_id" => ctx.tenant_id,
          "mode" => "mode_a",
          "bank" => ctx.bank,
          "role_name" => ctx.role_name,
          "prefix" => ctx.prefix,
          "embedding_dim" => nil
        },
        "tenant_scope" => %{
          "tenant_ids" => [ctx.tenant_id],
          "roles" => [ctx.role_name],
          "prefixes" => [ctx.prefix]
        },
        "payload" => %{
          "bank_id" => ctx.bank,
          "source_prefix" => "tenant_source_http_fail",
          "target_prefix" => "tenant_target_http_fail",
          "async" => false
        }
      }
      |> Job.new(
        worker: MigrateBankWorker,
        queue: "foresight_migrate_bank",
        state: "discarded",
        attempt: 1,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now,
        discarded_at: now,
        errors: [%{"attempt" => 1, "at" => DateTime.to_iso8601(now), "error" => "probe failed"}],
        meta: %{
          "operation_result" => %{
            "diagnostic_type" => "migration_diagnostics",
            "stage" => "probe",
            "failure_kind" => "parity_probe_failed",
            "bank_id" => ctx.bank,
            "source_prefix" => "tenant_source_http_fail",
            "target_prefix" => "tenant_target_http_fail",
            "migration_policy" => %{
              "excluded_surfaces" => ["audit_log"]
            },
            "target_provisioned" => %{
              "prefix" => "tenant_target_http_fail",
              "migrated_versions" => []
            },
            "detail" => %{
              "parity_probe" => %{
                "clean?" => false,
                "mismatched_memory_unit_ids" => ["mu-http-fail"]
              }
            }
          }
        }
      )
      |> Foresight.Repo.insert!()

    expected_id = Integer.to_string(job.id)
    expected_bank_id = ctx.bank

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    router_config = %{
      auth: %{
        api_key: "secret",
        tenant_scopes: %{
          "secret" => %{
            tenant_ids: [ctx.tenant_id],
            roles: [ctx.role_name],
            prefixes: [ctx.prefix]
          }
        }
      },
      http: %{enabled: true},
      health: %{checker: Foresight.Health},
      ml: %{enabled: false},
      oban: %{enabled: false},
      repo: %{enabled: false}
    }

    list_conn =
      conn(:get, "/v1/default/banks/#{ctx.bank}/operations?limit=10&offset=0")
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("x-foresight-tenant-id", ctx.tenant_id)
      |> put_req_header("x-foresight-role", ctx.role_name)
      |> put_req_header("x-foresight-prefix", ctx.prefix)
      |> Router.call(Router.init(config: router_config))

    assert list_conn.status == 200

    assert %{
             "bank_id" => ^expected_bank_id,
             "operations" => [
               %{
                 "id" => ^expected_id,
                 "task_type" => "migrate_bank",
                 "status" => "failed",
                 "error_message" => "probe failed",
                 "retry_count" => 1,
                 "next_retry_at" => nil,
                 "result_diagnostic_type" => "migration_diagnostics",
                 "result_stage" => "probe",
                 "result_failure_kind" => "parity_probe_failed",
                 "result_has_probe_drift" => true
               }
             ]
           } = Jason.decode!(list_conn.resp_body)

    detail_conn =
      conn(:get, "/v1/default/banks/#{ctx.bank}/operations/#{expected_id}")
      |> put_req_header("authorization", "Bearer secret")
      |> put_req_header("x-foresight-tenant-id", ctx.tenant_id)
      |> put_req_header("x-foresight-role", ctx.role_name)
      |> put_req_header("x-foresight-prefix", ctx.prefix)
      |> Router.call(Router.init(config: router_config))

    assert detail_conn.status == 200

    assert %{
             "operation_id" => ^expected_id,
             "status" => "failed",
             "operation_type" => "migrate_bank",
             "error_message" => "probe failed",
             "retry_count" => 1,
             "next_retry_at" => nil,
             "result_diagnostic_type" => "migration_diagnostics",
             "result_stage" => "probe",
             "result_failure_kind" => "parity_probe_failed",
             "result_has_probe_drift" => true,
             "result" => %{
               "diagnostic_type" => "migration_diagnostics",
               "stage" => "probe",
               "failure_kind" => "parity_probe_failed",
               "bank_id" => ^expected_bank_id,
               "source_prefix" => "tenant_source_http_fail",
               "target_prefix" => "tenant_target_http_fail",
               "migration_policy" => %{"excluded_surfaces" => ["audit_log"]},
               "target_provisioned" => %{
                 "prefix" => "tenant_target_http_fail",
                 "migrated_versions" => []
               },
               "detail" => %{
                 "parity_probe" => %{
                   "clean?" => false,
                   "mismatched_memory_unit_ids" => ["mu-http-fail"]
                 }
               }
             }
           } = Jason.decode!(detail_conn.resp_body)
  end

  test "real store bank_stats reflects queued operation lifecycle counts" do
    create_oban_jobs_table!()
    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    assert {:ok, _} =
             SQL.query(Foresight.Repo, "TRUNCATE TABLE public.oban_jobs RESTART IDENTITY", [])

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    retry_at = DateTime.add(now, 60, :second)
    prefix = "tenant_bank_stats_op"

    assert {:ok, _} = SQL.query(Foresight.Repo, "CREATE SCHEMA tenant_bank_stats_op", [])

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true, prefix: prefix)
      end)

    ctx = %Context{
      tenant_id: "tenant-bank-stats-op",
      mode: :mode_a,
      bank: "bank-stats-op",
      role_name: "reader",
      prefix: prefix
    }

    %{
      "context" => %{
        "tenant_id" => ctx.tenant_id,
        "mode" => "mode_a",
        "bank" => ctx.bank,
        "role_name" => ctx.role_name,
        "prefix" => ctx.prefix,
        "embedding_dim" => nil
      },
      "tenant_scope" => %{
        "tenant_ids" => [ctx.tenant_id],
        "roles" => [ctx.role_name],
        "prefixes" => [ctx.prefix]
      },
      "payload" => %{
        "async" => false,
        "items" => [%{"content" => "queued memory", "context" => "chat"}]
      }
    }
    |> Job.new(
      worker: RetainWorker,
      queue: "foresight_retain",
      state: "retryable",
      attempt: 2,
      max_attempts: 5,
      inserted_at: now,
      scheduled_at: retry_at,
      attempted_at: now,
      errors: [
        %{"attempt" => 1, "at" => DateTime.to_iso8601(now), "error" => "transient retain failure"}
      ]
    )
    |> Foresight.Repo.insert!()

    %{
      "context" => %{
        "tenant_id" => ctx.tenant_id,
        "mode" => "mode_a",
        "bank" => ctx.bank,
        "role_name" => ctx.role_name,
        "prefix" => ctx.prefix,
        "embedding_dim" => nil
      },
      "tenant_scope" => %{
        "tenant_ids" => [ctx.tenant_id],
        "roles" => [ctx.role_name],
        "prefixes" => [ctx.prefix]
      },
      "payload" => %{
        "bank_id" => ctx.bank,
        "source_prefix" => "tenant_source_stats_fail",
        "target_prefix" => "tenant_target_stats_fail",
        "async" => false
      }
    }
    |> Job.new(
      worker: MigrateBankWorker,
      queue: "foresight_migrate_bank",
      state: "discarded",
      attempt: 1,
      max_attempts: 5,
      inserted_at: now,
      scheduled_at: now,
      attempted_at: now,
      discarded_at: now,
      errors: [%{"attempt" => 1, "at" => DateTime.to_iso8601(now), "error" => "probe failed"}]
    )
    |> Foresight.Repo.insert!()

    %{
      "context" => %{
        "tenant_id" => ctx.tenant_id,
        "mode" => "mode_a",
        "bank" => ctx.bank,
        "role_name" => ctx.role_name,
        "prefix" => ctx.prefix,
        "embedding_dim" => nil
      },
      "tenant_scope" => %{
        "tenant_ids" => [ctx.tenant_id],
        "roles" => [ctx.role_name],
        "prefixes" => [ctx.prefix]
      },
      "payload" => %{
        "async" => false,
        "items" => [%{"content" => "cancelled memory", "context" => "chat"}]
      }
    }
    |> Job.new(
      worker: RetainWorker,
      queue: "foresight_retain",
      state: "cancelled",
      attempt: 1,
      max_attempts: 5,
      inserted_at: now,
      scheduled_at: now,
      attempted_at: now,
      cancelled_at: now
    )
    |> Foresight.Repo.insert!()

    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban
    )

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

    assert {:ok,
            %{
              "bank_id" => "bank-stats-op",
              "pending_operations" => 1,
              "failed_operations" => 1,
              "operations_by_status" => %{
                "pending" => 1,
                "failed" => 1,
                "cancelled" => 1
              }
            }} = Foresight.bank_stats(ctx, "bank-stats-op")
  end

  defp create_oban_jobs_table! do
    SQL.query!(
      Foresight.Repo,
      """
      CREATE TABLE IF NOT EXISTS public.oban_jobs (
        id bigserial PRIMARY KEY,
        state varchar NOT NULL DEFAULT 'available',
        queue varchar NOT NULL DEFAULT 'default',
        worker varchar NOT NULL,
        args jsonb NOT NULL,
        meta jsonb NOT NULL DEFAULT '{}'::jsonb,
        tags text[] NOT NULL DEFAULT ARRAY[]::text[],
        errors jsonb[] NOT NULL DEFAULT ARRAY[]::jsonb[],
        attempt integer NOT NULL DEFAULT 0,
        attempted_by text[],
        max_attempts integer NOT NULL DEFAULT 20,
        priority integer NOT NULL DEFAULT 0,
        attempted_at timestamp(6) with time zone,
        cancelled_at timestamp(6) with time zone,
        completed_at timestamp(6) with time zone,
        discarded_at timestamp(6) with time zone,
        inserted_at timestamp(6) with time zone NOT NULL,
        scheduled_at timestamp(6) with time zone NOT NULL
      )
      """,
      []
    )
  end
end
