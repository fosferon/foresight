defmodule Foresight.Jobs.TenantScopeTest do
  use ExUnit.Case, async: false

  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.AsyncQueues.Oban, as: ObanQueue
  alias Foresight.Jobs.ConsolidateWorker
  alias Foresight.Jobs.EmbeddingBackfillWorker
  alias Foresight.Jobs.MigrateBankWorker
  alias Foresight.Jobs.RetainWorker
  alias Foresight.TestSupport.FakeAsyncQueue

  defmodule WorkerStorageSpy do
    def retain(ctx, payload, _opts) do
      send(self(), {:retain_called, ctx, payload})
      {:ok, %{"success" => true}}
    end

    def consolidate(ctx, payload, _opts) do
      send(self(), {:consolidate_called, ctx, payload})
      {:ok, %{"success" => true}}
    end

    def backfill_embeddings(ctx, payload, _opts) do
      send(self(), {:embedding_backfill_called, ctx, payload})
      {:ok, %{"success" => true, "updated_count" => 1}}
    end
  end

  defmodule WorkerMigratorSpy do
    def migrate(source_prefix, target_prefix, bank_id, opts) do
      send(self(), {:migrate_called, source_prefix, target_prefix, bank_id, opts})
      {:ok, %{bank_id: bank_id, source_prefix: source_prefix, target_prefix: target_prefix}}
    end
  end

  setup do
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :engine, %{
      storage: WorkerStorageSpy,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban,
      bank_migrator: WorkerMigratorSpy
    })

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    :ok
  end

  test "retain worker accepts matching tenant scope snapshot" do
    assert :ok =
             RetainWorker.perform(%Oban.Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-http",
                   "mode" => :mode_a,
                   "bank" => "fosferon",
                   "role_name" => "reader",
                   "prefix" => "tenant_http"
                 },
                 "tenant_scope" => %{
                   "tenant_ids" => ["tenant-http"],
                   "roles" => ["reader"],
                   "prefixes" => ["tenant_http"]
                 },
                 "payload" => %{"items" => [%{"content" => "hello", "context" => "chat"}]}
               }
             })

    assert_received {:retain_called,
                     %Context{
                       tenant_id: "tenant-http",
                       role_name: "reader",
                       prefix: "tenant_http",
                       bank: "fosferon"
                     }, %{"async" => false, "items" => [_]}}
  end

  test "consolidate worker rejects tenant scope drift before storage runs" do
    assert {:error, %Error{reason: :unauthorized} = error} =
             ConsolidateWorker.perform(%Oban.Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-other",
                   "mode" => :mode_a,
                   "bank" => "fosferon",
                   "role_name" => "reader",
                   "prefix" => "tenant_http"
                 },
                 "tenant_scope" => %{
                   "tenant_ids" => ["tenant-http"],
                   "roles" => ["reader"],
                   "prefixes" => ["tenant_http"]
                 },
                 "payload" => %{"scope_keys" => ["scope:1"]}
               }
             })

    assert error.detail == %{
             message: "requested tenant scope is not allowed for this job"
           }

    refute_received {:consolidate_called, _, _}
  end

  test "migrate_bank worker accepts matching tenant scope snapshot" do
    assert :ok =
             MigrateBankWorker.perform(%Oban.Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-http",
                   "mode" => :mode_a,
                   "bank" => "fosferon",
                   "role_name" => "reader",
                   "prefix" => "tenant_http"
                 },
                 "tenant_scope" => %{
                   "tenant_ids" => ["tenant-http"],
                   "roles" => ["reader"],
                   "prefixes" => ["tenant_http"]
                 },
                 "payload" => %{
                   "source_prefix" => "tenant_source",
                   "target_prefix" => "tenant_target"
                 }
               }
             })

    assert_received {:migrate_called, "tenant_source", "tenant_target", "fosferon", opts}
    assert Keyword.get(opts, :repo) == Foresight.Repo
  end

  test "migrate_bank worker rejects tenant scope drift before migrator runs" do
    assert {:error, %Error{reason: :unauthorized} = error} =
             MigrateBankWorker.perform(%Oban.Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-other",
                   "mode" => :mode_a,
                   "bank" => "fosferon",
                   "role_name" => "reader",
                   "prefix" => "tenant_http"
                 },
                 "tenant_scope" => %{
                   "tenant_ids" => ["tenant-http"],
                   "roles" => ["reader"],
                   "prefixes" => ["tenant_http"]
                 },
                 "payload" => %{
                   "source_prefix" => "tenant_source",
                   "target_prefix" => "tenant_target"
                 }
               }
             })

    assert error.detail == %{
             message: "requested tenant scope is not allowed for this job"
           }

    refute_received {:migrate_called, _, _, _, _}
  end

  test "embedding_backfill worker accepts matching tenant scope snapshot" do
    assert :ok =
             EmbeddingBackfillWorker.perform(%Oban.Job{
               args: %{
                 "context" => %{
                   "tenant_id" => "tenant-http",
                   "mode" => :mode_a,
                   "bank" => "fosferon",
                   "role_name" => "reader",
                   "prefix" => "tenant_http"
                 },
                 "tenant_scope" => %{
                   "tenant_ids" => ["tenant-http"],
                   "roles" => ["reader"],
                   "prefixes" => ["tenant_http"]
                 },
                 "payload" => %{
                   "bank_id" => "fosferon",
                   "target_profile" => %{"model_id" => "custom/model", "embedding_dim" => 384}
                 }
               }
             })

    assert_received {:embedding_backfill_called,
                     %Context{
                       tenant_id: "tenant-http",
                       role_name: "reader",
                       prefix: "tenant_http",
                       bank: "fosferon"
                     },
                     %{
                       "bank_id" => "fosferon",
                       "target_profile" => %{"model_id" => "custom/model", "embedding_dim" => 384}
                     }}
  end

  test "oban queue rejects broadened tenant scope snapshots at enqueue time" do
    ctx = %Context{
      tenant_id: "tenant-http",
      mode: :mode_a,
      bank: "fosferon",
      role_name: "reader",
      prefix: "tenant_http"
    }

    assert {:error, %Error{reason: :unauthorized} = error} =
             ObanQueue.enqueue_retain(
               ctx,
               %{"items" => [%{"content" => "hello", "context" => "chat"}]},
               tenant_scope: %{
                 "tenant_ids" => ["tenant-other"],
                 "roles" => ["reader"],
                 "prefixes" => ["tenant_http"]
               }
             )

    assert error.detail == %{
             message: "requested tenant scope is not allowed for this job"
           }
  end

  test "fake queue rejects broadened tenant scope snapshots at enqueue time" do
    start_supervised!({FakeAsyncQueue, []})

    ctx = %Context{
      tenant_id: "tenant-http",
      mode: :mode_a,
      bank: "fosferon",
      role_name: "reader",
      prefix: "tenant_http"
    }

    assert {:error, %Error{reason: :unauthorized} = error} =
             FakeAsyncQueue.enqueue_retain(
               ctx,
               %{"items" => [%{"content" => "hello", "context" => "chat"}]},
               tenant_scope: %{
                 "tenant_ids" => ["tenant-other"],
                 "roles" => ["reader"],
                 "prefixes" => ["tenant_http"]
               }
             )

    assert error.detail == %{
             message: "requested tenant scope is not allowed for this job"
           }
  end

  test "oban queue rejects broadened migrate_bank tenant scope snapshots at enqueue time" do
    ctx = %Context{
      tenant_id: "tenant-http",
      mode: :mode_a,
      bank: "fosferon",
      role_name: "reader",
      prefix: "tenant_http"
    }

    assert {:error, %Error{reason: :unauthorized} = error} =
             ObanQueue.enqueue_migrate_bank(
               ctx,
               %{"source_prefix" => "tenant_source", "target_prefix" => "tenant_target"},
               tenant_scope: %{
                 "tenant_ids" => ["tenant-other"],
                 "roles" => ["reader"],
                 "prefixes" => ["tenant_http"]
               }
             )

    assert error.detail == %{
             message: "requested tenant scope is not allowed for this job"
           }
  end

  test "fake queue rejects broadened migrate_bank tenant scope snapshots at enqueue time" do
    start_supervised!({FakeAsyncQueue, []})

    ctx = %Context{
      tenant_id: "tenant-http",
      mode: :mode_a,
      bank: "fosferon",
      role_name: "reader",
      prefix: "tenant_http"
    }

    assert {:error, %Error{reason: :unauthorized} = error} =
             FakeAsyncQueue.enqueue_migrate_bank(
               ctx,
               %{"source_prefix" => "tenant_source", "target_prefix" => "tenant_target"},
               tenant_scope: %{
                 "tenant_ids" => ["tenant-other"],
                 "roles" => ["reader"],
                 "prefixes" => ["tenant_http"]
               }
             )

    assert error.detail == %{
             message: "requested tenant scope is not allowed for this job"
           }
  end
end
