defmodule Foresight.Backend.StoreFileIngestionTest do
  use ExUnit.Case, async: false

  alias Foresight.Backend.Store
  alias Foresight.Context

  defmodule CaptureStorage do
    def retain(ctx, payload, _opts) do
      send(self(), {:captured_retain, ctx, payload})
      {:ok, %{"operation_id" => "file-op-1", "operation_ids" => ["file-op-1"]}}
    end
  end

  defmodule FakeDoclingWorker do
    def parse_with_metadata(_path) do
      {:ok,
       %{
         markdown: "Converted markdown body",
         metadata: %{"title" => "Docling Title", "format" => ".pdf"}
       }}
    end
  end

  defmodule ChunkingDoclingWorker do
    def parse_with_metadata(_path) do
      {:ok,
       %{
         markdown: "# Report\n\nRevenue was 4.2M.\n\nCosts were 1.1M.",
         metadata: %{"title" => "Report", "format" => ".pdf"},
         chunks: [
           %{"text" => "Report", "element_type" => "section_header", "page" => 1},
           %{"text" => "Revenue was 4.2M.", "element_type" => "paragraph", "page" => 1},
           %{"text" => "Costs were 1.1M.", "element_type" => "paragraph", "page" => 2}
         ]
       }}
    end
  end

  defmodule SymbolFirstChunkWorker do
    def parse_with_metadata(_path) do
      {:ok,
       %{
         markdown: "—\n\nRevenue was 4.2M.",
         metadata: %{"title" => "Report", "format" => ".pdf"},
         chunks: [
           # Non-alphanumeric leading chunk: dropped by the content filter, so it
           # must NOT be the sole carrier of the file bytes.
           %{"text" => "———", "element_type" => "paragraph", "page" => 1},
           %{"text" => "Revenue was 4.2M.", "element_type" => "paragraph", "page" => 1}
         ]
       }}
    end
  end

  setup do
    original_engine = Application.get_env(:foresight, :engine)
    original_ingestion = Application.get_env(:foresight, :file_ingestion)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end

      if original_ingestion do
        Application.put_env(:foresight, :file_ingestion, original_ingestion)
      else
        Application.delete_env(:foresight, :file_ingestion)
      end
    end)

    :ok
  end

  test "retain_files converts uploads and forwards file storage payload into retain" do
    path = Plug.Upload.random_file!("store-docling")
    File.write!(path, "binary file body")

    Application.put_env(
      :foresight,
      :engine,
      storage: CaptureStorage,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    Application.put_env(
      :foresight,
      :file_ingestion,
      enabled: true,
      converter: Foresight.DocumentConverters.Docling,
      converter_opts: [docling_worker: FakeDoclingWorker]
    )

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "fosferon"}

    assert {:ok, %{"operation_id" => "file-op-1", "operation_ids" => ["file-op-1"]}} =
             Store.retain_files(
               ctx,
               %{
                 "files" => [
                   %{
                     "path" => path,
                     "filename" => "manual.pdf",
                     "content_type" => "application/pdf",
                     "document_id" => "doc-1",
                     "metadata" => %{"source" => "test"}
                   }
                 ],
                 "request" => %{"tags" => ["alpha"], "context" => "file"}
               },
               []
             )

    assert_receive {:captured_retain, ^ctx, retain_payload}

    assert %{
             "items" => [
               %{
                 "content" => "Converted markdown body",
                 "document_id" => "doc-1",
                 "document_title" => "Docling Title",
                 "document_text" => "Converted markdown body",
                 "file_original_name" => "manual.pdf",
                 "file_content_type" => "application/pdf",
                 "file_storage_data" => "binary file body",
                 "tags" => ["alpha"]
               } = item
             ],
             "async" => true
           } = retain_payload

    assert is_binary(item["file_storage_key"])
    assert String.starts_with?(item["file_storage_key"], "file:doc-1:")
    assert item["metadata"]["source"] == "test"
    assert item["metadata"]["format"] == ".pdf"
  end

  test "structure-preserving ingestion emits one item per chunk with source_location" do
    path = Plug.Upload.random_file!("store-docling-chunks")
    File.write!(path, "binary file body")

    Application.put_env(
      :foresight,
      :engine,
      storage: CaptureStorage,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    Application.put_env(
      :foresight,
      :file_ingestion,
      enabled: true,
      converter: Foresight.DocumentConverters.Docling,
      converter_opts: [docling_worker: ChunkingDoclingWorker]
    )

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "fosferon"}

    assert {:ok, _} =
             Store.retain_files(
               ctx,
               %{
                 "files" => [
                   %{
                     "path" => path,
                     "filename" => "report.pdf",
                     "content_type" => "application/pdf",
                     "document_id" => "doc-2"
                   }
                 ],
                 "request" => %{"tags" => ["alpha"]}
               },
               []
             )

    assert_receive {:captured_retain, ^ctx, %{"items" => items}}

    # One memory item per structural chunk, all sharing the document.
    assert length(items) == 3
    assert Enum.all?(items, &(&1["document_id"] == "doc-2"))
    assert Enum.map(items, & &1["content"]) == ["Report", "Revenue was 4.2M.", "Costs were 1.1M."]

    # Each carries its own provenance; text is not duplicated into source_location.
    assert Enum.all?(items, &is_map(&1["source_location"]))

    assert Enum.at(items, 0)["source_location"] == %{
             "element_type" => "section_header",
             "page" => 1
           }

    assert Enum.at(items, 2)["source_location"]["page"] == 2
    refute Map.has_key?(Enum.at(items, 0)["source_location"], "text")

    # Original file bytes attached to the first chunk only (deduped by document).
    assert Enum.at(items, 0)["file_storage_data"] == "binary file body"
    refute Map.has_key?(Enum.at(items, 1), "file_storage_data")
    refute Map.has_key?(Enum.at(items, 2), "file_storage_data")
  end

  test "a non-alphanumeric leading chunk does not orphan the file bytes" do
    path = Plug.Upload.random_file!("store-docling-symbol")
    File.write!(path, "binary file body")

    Application.put_env(
      :foresight,
      :engine,
      storage: CaptureStorage,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    Application.put_env(
      :foresight,
      :file_ingestion,
      enabled: true,
      converter: Foresight.DocumentConverters.Docling,
      converter_opts: [docling_worker: SymbolFirstChunkWorker]
    )

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "fosferon"}

    assert {:ok, _} =
             Store.retain_files(
               ctx,
               %{
                 "files" => [%{"path" => path, "filename" => "r.pdf", "document_id" => "doc-3"}],
                 "request" => %{}
               },
               []
             )

    assert_receive {:captured_retain, ^ctx, %{"items" => items}}

    # The symbol-only chunk is filtered out; the surviving first chunk carries bytes.
    assert length(items) == 1
    assert Enum.at(items, 0)["content"] == "Revenue was 4.2M."
    assert Enum.at(items, 0)["file_storage_data"] == "binary file body"
  end

  describe "text bodies (Hindsight migration shape)" do
    setup do
      Application.put_env(
        :foresight,
        :engine,
        storage: CaptureStorage,
        repo: Foresight.Repo,
        embedder: Foresight.Embedders.Noop,
        reranker: Foresight.Rerankers.Passthrough,
        llm: Foresight.LLMs.Noop,
        queue: Foresight.AsyncQueues.Oban,
        oban_name: Foresight.Oban,
        reranker_serving_name: Foresight.ML.RerankerServing
      )

      # The configured converter is docling: text bodies must not reach it.
      Application.put_env(:foresight, :file_ingestion,
        enabled: true,
        converter: Foresight.DocumentConverters.Docling,
        converter_opts: [docling_worker: FakeDoclingWorker]
      )

      %{ctx: %Context{tenant_id: "default", mode: :mode_a, bank: "fosferon"}}
    end

    test "a %{\"text\" => body} file is retained as-is, synchronously on request", %{ctx: ctx} do
      assert {:ok, _} =
               Store.retain_files(
                 ctx,
                 %{
                   "files" => [
                     %{"text" => "Migrated body", "document_id" => "doc-7", "filename" => "n.txt"}
                   ],
                   "request" => %{"async" => false}
                 },
                 []
               )

      assert_receive {:captured_retain, ^ctx, %{"items" => [item], "async" => false}}
      assert item["content"] == "Migrated body"
      assert item["document_id"] == "doc-7"
      assert item["document_text"] == "Migrated body"
      refute Map.has_key?(item, "file_storage_data")
    end

    test "a text map without document_id or filename is content-addressed too", %{ctx: ctx} do
      assert {:ok, _} = Store.retain_files(ctx, %{"files" => [%{"text" => "alpha"}]}, [])
      assert_receive {:captured_retain, ^ctx, %{"items" => [a]}}
      assert {:ok, _} = Store.retain_files(ctx, %{"files" => [%{"text" => "beta"}]}, [])
      assert_receive {:captured_retain, ^ctx, %{"items" => [b]}}

      assert "text:" <> _ = a["document_id"]
      refute a["document_id"] == b["document_id"]
      refute a["document_id"] == "file-0"
    end

    test "null or empty ids count as absent for content-addressing", %{ctx: ctx} do
      assert {:ok, _} =
               Store.retain_files(
                 ctx,
                 %{"files" => [%{"text" => "alpha", "document_id" => nil, "filename" => ""}]},
                 []
               )

      assert_receive {:captured_retain, ^ctx, %{"items" => [item]}}
      assert "text:" <> _ = item["document_id"]
    end

    test "an empty-string document_id falls back to the filename like null does", %{ctx: ctx} do
      for blank <- [nil, ""] do
        assert {:ok, _} =
                 Store.retain_files(
                   ctx,
                   %{
                     "files" => [
                       %{"text" => "alpha", "document_id" => blank, "filename" => "a.txt"}
                     ]
                   },
                   []
                 )

        assert_receive {:captured_retain, ^ctx, %{"items" => [item]}}
        assert item["document_id"] == "a.txt"
      end
    end

    test "a blank text body is rejected loudly, not dropped", %{ctx: ctx} do
      for blank <- ["", "   \n", "---"] do
        assert {:error, %Foresight.Error{reason: :invalid_request}} =
                 Store.retain_files(
                   ctx,
                   %{"files" => [%{"text" => blank, "document_id" => "d"}]},
                   []
                 )
      end

      refute_receive {:captured_retain, _, _}
    end

    test "a non-binary text value gets the text converter's error, not docling's", %{ctx: ctx} do
      assert {:error, %Foresight.Error{reason: :invalid_request, detail: %{message: message}}} =
               Store.retain_files(ctx, %{"files" => [%{"text" => 123}]}, [])

      assert message =~ "text"
      refute message =~ "docling"
    end

    test "a text body never reads path, even a missing one", %{ctx: ctx} do
      assert {:ok, _} =
               Store.retain_files(
                 ctx,
                 %{
                   "files" => [
                     %{"text" => "Body", "document_id" => "d", "path" => "/nonexistent"}
                   ]
                 },
                 []
               )

      assert_receive {:captured_retain, ^ctx, %{"items" => [item]}}
      assert item["content"] == "Body"
      refute Map.has_key?(item, "file_storage_data")
    end

    test "update_mode is opt-in, from the file or the request", %{ctx: ctx} do
      assert {:ok, _} =
               Store.retain_files(
                 ctx,
                 %{"files" => [%{"text" => "Body", "document_id" => "d"}]},
                 []
               )

      assert_receive {:captured_retain, ^ctx, %{"items" => [default]}}
      refute Map.has_key?(default, "update_mode")

      assert {:ok, _} =
               Store.retain_files(
                 ctx,
                 %{
                   "files" => [%{"text" => "Body", "document_id" => "d"}],
                   "request" => %{"update_mode" => "replace"}
                 },
                 []
               )

      assert_receive {:captured_retain, ^ctx, %{"items" => [from_request]}}
      assert from_request["update_mode"] == "replace"
    end

    test "a bare binary gets a content-addressed document_id", %{ctx: ctx} do
      assert {:ok, _} = Store.retain_files(ctx, %{"files" => ["alpha", "beta"]}, [])

      assert_receive {:captured_retain, ^ctx, %{"items" => [a, b]}}
      assert a["content"] == "alpha"
      assert b["content"] == "beta"
      assert "text:" <> _ = a["document_id"]
      refute a["document_id"] == b["document_id"]
    end
  end
end
