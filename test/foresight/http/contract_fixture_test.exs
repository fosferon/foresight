defmodule Foresight.HTTP.ContractFixtureTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Foresight.Context

  @recorded_fixture_root Path.expand(
                           "../../../priv/foresight/fixtures/recorded_floor_contract",
                           __DIR__
                         )
  @synthetic_fixture_root Path.expand("../../../priv/foresight/fixtures/floor_contract", __DIR__)
  @fixture_bank_id "foresight-floor"
  @synthetic_only_fixtures MapSet.new([
                             "retain_operation.json",
                             "retain_operations_list.json",
                             "consolidate_operation.json",
                             "consolidate_operations_list.json"
                           ])

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    healthy_repo = start_supervised!({Foresight.TestSupport.FakeRepo, []})
    start_supervised!({Foresight.TestSupport.FakeAsyncQueue, []})
    start_supervised!({Foresight.TestSupport.FakeStorage, []})
    Foresight.TestSupport.FakeAsyncQueue.reset!()
    Foresight.TestSupport.FakeStorage.reset!()

    Application.put_env(:foresight, :backend, Foresight.TestSupport.RecordedContractBackend)

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

    {:ok, healthy_repo: healthy_repo}
  end

  test "FLOOR fixtures match current HTTP contract", %{healthy_repo: healthy_repo} do
    cases = [
      {"health.json", 200, conn(:get, "/health"), health_config(healthy_repo), fn -> :ok end},
      {"version.json", 200, conn(:get, "/version"), version_config(), fn -> :ok end},
      {"retain_async.json", 200, retain_async_conn(), default_config(), fn -> :ok end},
      {"consolidate_trigger.json", 200, consolidate_conn(), default_config(), fn -> :ok end},
      {"files_retain.json", 200, files_retain_conn(), default_config(), fn -> :ok end},
      {"retain_operation.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations/1"), default_config(),
       fn -> prepare_retain_operation_fixture() end},
      {"retain_operations_list.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations?limit=10&offset=0"),
       default_config(), fn -> prepare_retain_operations_list_fixture() end},
      {"consolidate_operation.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations/1"), default_config(),
       fn -> prepare_consolidate_operation_fixture() end},
      {"consolidate_operations_list.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations?limit=10&offset=0"),
       default_config(), fn -> prepare_consolidate_operations_list_fixture() end},
      {"recall.json", 200, recall_conn(), default_config(), fn -> :ok end},
      {"reflect.json", 200, reflect_conn(), default_config(), fn -> :ok end},
      {"banks_list.json", 200, conn(:get, "/v1/default/banks"), default_config(), fn -> :ok end},
      {"bank_put.json", 200, put_bank_conn(), default_config(), fn -> :ok end},
      {"bank_delete.json", 200, conn(:delete, "/v1/default/banks/#{@fixture_bank_id}"),
       default_config(), fn -> :ok end},
      {"bank_stats.json", 200, conn(:get, "/v1/default/banks/#{@fixture_bank_id}/stats"),
       default_config(), fn -> :ok end},
      {"bank_profile.json", 200, conn(:get, "/v1/default/banks/#{@fixture_bank_id}/profile"),
       default_config(), fn -> :ok end},
      {"bank_patch.json", 200, patch_bank_conn(), default_config(), fn -> :ok end},
      {"directives_list.json", 200, fixture_request_conn!("directives_list.json"),
       default_config(), fn -> :ok end},
      {"directive_create.json", 200, directive_create_conn(), default_config(), fn -> :ok end},
      {"directive_get.json", 200, fixture_request_conn!("directive_get.json"), default_config(),
       fn -> :ok end},
      {"directive_patch.json", 200, directive_patch_conn(), default_config(), fn -> :ok end},
      {"directive_delete.json", 200, fixture_request_conn!("directive_delete.json"),
       default_config(), fn -> :ok end},
      {"mental_models_list.json", 200, fixture_request_conn!("mental_models_list.json"),
       default_config(), fn -> :ok end},
      {"mental_model_create.json", 200, mental_model_create_conn(), default_config(),
       fn -> :ok end},
      {"mental_model_get.json", 200, fixture_request_conn!("mental_model_get.json"),
       default_config(), fn -> :ok end},
      {"mental_model_history.json", 200, fixture_request_conn!("mental_model_history.json"),
       default_config(), fn -> :ok end},
      {"mental_model_refresh.json", 200, mental_model_refresh_conn(), default_config(),
       fn -> :ok end},
      {"mental_model_patch.json", 200, mental_model_patch_conn(), default_config(),
       fn -> :ok end},
      {"mental_model_delete.json", 200, fixture_request_conn!("mental_model_delete.json"),
       default_config(), fn -> :ok end},
      {"webhook_create.json", 201, webhook_create_conn(), default_config(), fn -> :ok end},
      {"webhooks_list.json", 200, fixture_request_conn!("webhooks_list.json"), default_config(),
       fn -> :ok end},
      {"webhook_patch.json", 200, webhook_patch_conn(), default_config(), fn -> :ok end},
      {"webhook_deliveries_list.json", 200, fixture_request_conn!("webhook_deliveries_list.json"),
       default_config(), fn -> :ok end},
      {"webhook_delete.json", 200, fixture_request_conn!("webhook_delete.json"), default_config(),
       fn -> :ok end},
      {"memories_list.json", 200,
       conn(
         :get,
         "/v1/default/banks/#{@fixture_bank_id}/memories/list?limit=5&offset=2&q=hello&type=note"
       ), default_config(), fn -> :ok end},
      {"memory_get.json", 200, fixture_request_conn!("memory_get.json"), default_config(),
       fn -> :ok end},
      {"memory_history.json", 200, fixture_request_conn!("memory_history.json"), default_config(),
       fn -> :ok end},
      {"entities_list.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/entities?limit=3&offset=1"),
       default_config(), fn -> :ok end},
      {"entity_graph.json", 200, fixture_request_conn!("entity_graph.json"), default_config(),
       fn -> :ok end},
      {"entity_get.json", 200, fixture_request_conn!("entity_get.json"), default_config(),
       fn -> :ok end},
      {"entity_regenerate_gone.json", 410, fixture_request_conn!("entity_regenerate_gone.json"),
       default_config(), fn -> :ok end},
      {"documents_list.json", 200,
       conn(
         :get,
         "/v1/default/banks/#{@fixture_bank_id}/documents?q=doc-7&tags[]=alpha&tags[]=beta"
       ), default_config(), fn -> :ok end},
      {"document_get.json", 200, fixture_request_conn!("document_get.json"), default_config(),
       fn -> :ok end},
      {"document_chunks.json", 200, fixture_request_conn!("document_chunks.json"),
       default_config(), fn -> :ok end},
      {"document_patch.json", 200, document_patch_conn(), default_config(), fn -> :ok end},
      {"document_reprocess.json", 200, document_reprocess_conn(), default_config(),
       fn -> :ok end},
      {"document_delete.json", 200, fixture_request_conn!("document_delete.json"),
       default_config(), fn -> :ok end},
      {"memory_graph.json", 200, fixture_request_conn!("memory_graph.json"), default_config(),
       fn -> :ok end},
      {"chunk_get.json", 200, fixture_request_conn!("chunk_get.json"), default_config(),
       fn -> :ok end},
      {"clear_observations.json", 200,
       conn(:delete, "/v1/default/banks/#{@fixture_bank_id}/observations"), default_config(),
       fn -> :ok end},
      {"clear_memory_observations.json", 200,
       fixture_request_conn!("clear_memory_observations.json"), default_config(), fn -> :ok end},
      {"clear_memories.json", 200,
       conn(:delete, "/v1/default/banks/#{@fixture_bank_id}/memories"), default_config(),
       fn -> :ok end},
      {"migrate_bank.json", 200, migrate_bank_conn(false), default_config(),
       fn -> put_migration_engine(Foresight.TestSupport.RouterMigrationOperationSpy) end},
      {"migrate_bank_async.json", 200, migrate_bank_conn(true), default_config(),
       fn ->
         Foresight.TestSupport.FakeAsyncQueue.reset!()
         put_migration_engine(Foresight.TestSupport.RouterMigrationOperationSpy)
       end},
      {"migration_operations_list.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations?limit=10&offset=0"),
       default_config(), fn -> prepare_migration_operations_list_fixture() end},
      {"migrate_bank_operation.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations/1"), default_config(),
       fn -> prepare_migrate_bank_operation_fixture() end},
      {"probe_bank_migration.json", 200, probe_bank_conn(false), default_config(),
       fn -> put_migration_engine(Foresight.TestSupport.RouterMigrationProbeSpy) end},
      {"probe_bank_migration_async.json", 200, probe_bank_conn(true), default_config(),
       fn ->
         Foresight.TestSupport.FakeAsyncQueue.reset!()
         put_migration_engine(Foresight.TestSupport.RouterMigrationProbeSpy)
       end},
      {"probe_bank_migration_operation.json", 200,
       conn(:get, "/v1/default/banks/#{@fixture_bank_id}/operations/1"), default_config(),
       fn -> prepare_probe_bank_operation_fixture() end}
    ]

    Enum.each(cases, fn {fixture_name, expected_status, request_conn, config, prepare} ->
      Foresight.TestSupport.FakeAsyncQueue.reset!()
      Foresight.TestSupport.FakeStorage.reset!()
      Application.put_env(:foresight, :backend, Foresight.TestSupport.RecordedContractBackend)
      Application.delete_env(:foresight, :engine)
      prepare.()

      conn =
        request_conn
        |> Foresight.HTTP.Router.call(Foresight.HTTP.Router.init(config: config))

      assert conn.status == expected_status,
             "fixture #{fixture_name} returned #{conn.status}: #{conn.resp_body}"

      assert normalize_fixture_response(fixture_name, Jason.decode!(conn.resp_body)) ==
               load_fixture(fixture_name)
    end)
  end

  defp default_config do
    %{
      auth: %{api_key: nil},
      file_ingestion: %{enabled: true},
      http: %{enabled: true},
      health: %{checker: Foresight.Health},
      ml: %{enabled: false},
      oban: %{enabled: false},
      repo: %{enabled: false}
    }
  end

  defp health_config(repo_name) do
    %{
      http: %{enabled: true},
      ml: %{enabled: false},
      oban: %{enabled: false},
      repo: %{enabled: true, module: Foresight.TestSupport.FakeRepo, name: repo_name}
    }
  end

  defp version_config do
    %{
      auth: %{api_key: nil},
      file_ingestion: %{enabled: true},
      http: %{enabled: true},
      mcp: %{enabled: true},
      ml: %{enabled: false},
      oban: %{enabled: true},
      repo: %{enabled: false}
    }
  end

  defp retain_async_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/memories",
      Jason.encode!(%{
        "items" => [%{"content" => "hello", "context" => "world"}],
        "async" => true
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp recall_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/memories/recall",
      Jason.encode!(%{
        "query" => "hello",
        "tags" => ["memory"],
        "max_tokens" => 4096,
        "trace" => true,
        "include" => %{"chunks" => %{}, "source_facts" => %{}}
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp files_retain_conn do
    path = Plug.Upload.random_file!("contract-fixture-files")
    File.write!(path, "live fixture upload body\n")
    boundary = "----foresight-contract-files-boundary"

    body =
      multipart_body(boundary, [
        {:file, "files", path, "fixture.txt", "text/plain"},
        {:field, "request",
         Jason.encode!(%{
           "files_metadata" => [
             %{
               "document_id" => "doc-live-upload",
               "metadata" => %{"source" => "live-fixture"}
             }
           ]
         })}
      ])

    conn(:post, "/v1/default/banks/#{@fixture_bank_id}/files/retain", body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
  end

  defp consolidate_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/consolidate",
      Jason.encode!(%{})
    )
    |> put_req_header("content-type", "application/json")
  end

  defp reflect_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/reflect",
      Jason.encode!(%{
        "query" => "hello",
        "include" => %{"facts" => %{}, "tool_calls" => %{}},
        "response_schema" => %{"type" => "object"}
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp put_bank_conn do
    conn(
      :put,
      "/v1/default/banks/#{@fixture_bank_id}",
      Jason.encode!(%{"name" => "Fosferon", "mission" => "Remember"})
    )
    |> put_req_header("content-type", "application/json")
  end

  defp patch_bank_conn do
    conn(
      :patch,
      "/v1/default/banks/#{@fixture_bank_id}",
      Jason.encode!(%{"mission" => "patched mission"})
    )
    |> put_req_header("content-type", "application/json")
  end

  defp directive_create_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/directives",
      Jason.encode!(%{
        "name" => "Fixture Directive",
        "content" => "Lead with evidence.",
        "priority" => 3,
        "is_active" => true,
        "tags" => ["alpha"]
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp directive_patch_conn do
    conn(
      :patch,
      fixture_request_path!("directive_patch.json"),
      Jason.encode!(%{
        "content" => "Lead with concrete evidence.",
        "tags" => ["alpha", "beta"]
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp document_patch_conn do
    conn(
      :patch,
      fixture_request_path!("document_patch.json"),
      Jason.encode!(%{"tags" => ["alpha", "beta", "live-recorded"]})
    )
    |> put_req_header("content-type", "application/json")
  end

  defp document_reprocess_conn do
    conn(
      :post,
      fixture_request_path!("document_reprocess.json"),
      Jason.encode!(%{})
    )
    |> put_req_header("content-type", "application/json")
  end

  defp mental_model_create_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/mental-models",
      Jason.encode!(%{
        "id" => "fixture-mental-model",
        "name" => "Fixture Mental Model",
        "source_query" => "What do we know about the seeded hello memory?",
        "tags" => ["alpha"]
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp mental_model_refresh_conn do
    conn(
      :post,
      fixture_request_path!("mental_model_refresh.json"),
      Jason.encode!(%{})
    )
    |> put_req_header("content-type", "application/json")
  end

  defp mental_model_patch_conn do
    conn(
      :patch,
      fixture_request_path!("mental_model_patch.json"),
      Jason.encode!(%{
        "name" => "Fixture Mental Model Updated",
        "source_query" => "What do we know about the seeded alpha memory?",
        "tags" => ["alpha", "beta"],
        "max_tokens" => 1024,
        "trigger" => %{"refresh_after_consolidation" => true}
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp webhook_create_conn do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/webhooks",
      Jason.encode!(%{
        "url" => "http://127.0.0.1:1/foresight-webhook-fixture",
        "secret" => "sk-webhook-fixture-secret",
        "event_types" => ["consolidation.completed"],
        "enabled" => true,
        "http_config" => %{
          "method" => "POST",
          "timeout_seconds" => 3,
          "headers" => %{"x-source" => "foresight-live-fixture"},
          "params" => %{"mode" => "fixture"}
        }
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp webhook_patch_conn do
    conn(
      :patch,
      fixture_request_path!("webhook_patch.json"),
      Jason.encode!(%{
        "enabled" => false,
        "http_config" => %{
          "method" => "GET",
          "timeout_seconds" => 5,
          "headers" => %{},
          "params" => %{"mode" => "fixture-patched"}
        }
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp migrate_bank_conn(async?) do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/migrations",
      Jason.encode!(%{
        "source_prefix" => "tenant_source",
        "target_prefix" => "tenant_target",
        "async" => async?
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp probe_bank_conn(async?) do
    conn(
      :post,
      "/v1/default/banks/#{@fixture_bank_id}/migrations/probe",
      Jason.encode!(%{
        "source_prefix" => "tenant_source",
        "target_prefix" => "tenant_target",
        "async" => async?
      })
    )
    |> put_req_header("content-type", "application/json")
  end

  defp put_migration_engine(bank_migrator) do
    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      bank_migrator: bank_migrator
    )
  end

  defp prepare_migrate_bank_operation_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()
    put_migration_engine(Foresight.TestSupport.RouterMigrationOperationSpy)

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.migrate_bank(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{
                 "source_prefix" => "tenant_source",
                 "target_prefix" => "tenant_target",
                 "async" => true
               }
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()

    assert {:ok, _} =
             Foresight.get_operation(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               "1"
             )
  end

  defp prepare_retain_operation_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.TestSupport.FakeStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.retain(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{
                 "items" => [%{"content" => "hello", "context" => "world"}],
                 "async" => true
               }
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()

    assert {:ok, _} =
             Foresight.get_operation(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               "1"
             )
  end

  defp prepare_retain_operations_list_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.TestSupport.FakeStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.retain(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{
                 "items" => [%{"content" => "hello", "context" => "world"}],
                 "async" => true
               }
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()
  end

  defp prepare_consolidate_operation_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()
    Foresight.TestSupport.FakeStorage.reset!()

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.TestSupport.FakeStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.consolidate(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{"tag_scopes" => [%{"tags" => ["alpha"]}], "async" => true}
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()

    assert {:ok, _} =
             Foresight.get_operation(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               "1"
             )
  end

  defp prepare_consolidate_operations_list_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()
    Foresight.TestSupport.FakeStorage.reset!()

    Application.put_env(
      :foresight,
      :engine,
      storage: Foresight.TestSupport.FakeStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue
    )

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.consolidate(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{"tag_scopes" => [%{"tags" => ["alpha"]}], "async" => true}
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()
  end

  defp prepare_migration_operations_list_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()
    put_migration_engine(Foresight.TestSupport.RouterMigrationDualSpy)

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.migrate_bank(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{
                 "source_prefix" => "tenant_source",
                 "target_prefix" => "tenant_target",
                 "async" => true
               }
             )

    assert {:ok, %{"operation_id" => "2"}} =
             Foresight.probe_bank_migration(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{
                 "source_prefix" => "tenant_source",
                 "target_prefix" => "tenant_target",
                 "async" => true
               }
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()
  end

  defp prepare_probe_bank_operation_fixture do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Foresight.TestSupport.FakeAsyncQueue.reset!()
    put_migration_engine(Foresight.TestSupport.RouterMigrationProbeSpy)

    assert {:ok, %{"operation_id" => "1"}} =
             Foresight.probe_bank_migration(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               %{
                 "source_prefix" => "tenant_source",
                 "target_prefix" => "tenant_target",
                 "async" => true
               }
             )

    Foresight.TestSupport.FakeAsyncQueue.drain!()

    assert {:ok, _} =
             Foresight.get_operation(
               %Context{tenant_id: "default", mode: :mode_a, bank: @fixture_bank_id},
               "1"
             )
  end

  defp normalize_fixture_response("migrate_bank_operation.json", payload),
    do: normalize_operation_timestamps(payload)

  defp normalize_fixture_response("migration_operations_list.json", payload),
    do: normalize_operation_list_timestamps(payload)

  defp normalize_fixture_response("probe_bank_migration_operation.json", payload),
    do: normalize_operation_timestamps(payload)

  defp normalize_fixture_response("retain_operation.json", payload),
    do: normalize_operation_timestamps(payload)

  defp normalize_fixture_response("retain_operations_list.json", payload),
    do: normalize_operation_list_timestamps(payload)

  defp normalize_fixture_response("consolidate_operation.json", payload),
    do: normalize_operation_timestamps(payload)

  defp normalize_fixture_response("consolidate_operations_list.json", payload),
    do: normalize_operation_list_timestamps(payload)

  defp normalize_fixture_response(_fixture_name, payload), do: payload

  defp normalize_operation_timestamps(%{} = payload) do
    payload
    |> Map.put("created_at", "<timestamp>")
    |> Map.put("updated_at", "<timestamp>")
    |> Map.put("completed_at", "<timestamp>")
  end

  defp normalize_operation_list_timestamps(%{"operations" => operations} = payload) do
    normalized =
      Enum.map(operations, fn operation ->
        Map.put(operation, "created_at", "<timestamp>")
      end)

    Map.put(payload, "operations", normalized)
  end

  defp load_fixture(name) do
    fixture_root(name)
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp fixture_request_conn!(name) do
    method =
      manifest_fixture!(name)
      |> Map.fetch!("method")
      |> String.downcase()
      |> String.to_atom()

    conn(method, fixture_request_path!(name))
  end

  defp fixture_request_path!(name) do
    manifest_fixture!(name)
    |> Map.fetch!("path")
  end

  defp manifest_fixture!(name) do
    manifest_fixture =
      @recorded_fixture_root
      |> Path.join("manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("fixtures")
      |> Enum.find(&(Map.get(&1, "name") == name))

    if manifest_fixture do
      manifest_fixture
    else
      raise "missing recorded manifest entry for #{name}"
    end
  end

  defp fixture_root(name) do
    if MapSet.member?(@synthetic_only_fixtures, name) do
      @synthetic_fixture_root
    else
      @recorded_fixture_root
    end
  end

  defp multipart_body(boundary, parts) do
    parts
    |> Enum.map_join(&multipart_part(boundary, &1))
    |> Kernel.<>("--#{boundary}--\r\n")
  end

  defp multipart_part(boundary, {:field, name, value}) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"\r\n",
      "\r\n",
      value,
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp multipart_part(boundary, {:file, name, path, filename, content_type}) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n",
      "content-type: #{content_type}\r\n",
      "\r\n",
      File.read!(path),
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end
end
