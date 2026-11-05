defmodule Foresight.HTTP.HindsightWireTest do
  use ExUnit.Case, async: true

  alias Foresight.HTTP.HindsightWire

  test "a client-supplied file path is stripped (arbitrary host-file-read guard)" do
    assert {:ok, %{"files" => [file]}} =
             HindsightWire.normalize_file_retain_payload(%{
               "files" => [
                 %{
                   "path" => "/etc/passwd",
                   "filename" => "x.pdf",
                   "content_type" => "application/pdf"
                 }
               ]
             })

    # The trusted path only comes from a server Plug.Upload; a JSON-body path must
    # never reach file_bytes/docling (both File.read it).
    refute Map.has_key?(file, "path")
    assert file["filename"] == "x.pdf"
  end

  test "retain_response preserves async alias and explicit nil async companion fields" do
    assert HindsightWire.retain_response(%{
             "success" => true,
             "bank_id" => "foresight-floor",
             "items_count" => 1,
             "async" => true,
             "operation_id" => "op-1",
             "operation_ids" => nil,
             "usage" => nil
           }) == %{
             "success" => true,
             "bank_id" => "foresight-floor",
             "items_count" => 1,
             "async" => true,
             "operation_id" => "op-1",
             "operation_ids" => nil,
             "usage" => nil
           }
  end

  test "retain_response preserves trace when present" do
    assert HindsightWire.retain_response(%{
             "success" => true,
             "bank_id" => "foresight-floor",
             "items_count" => 1,
             "async" => false,
             "trace" => %{"timings_ms" => %{"total_ms" => 123}}
           }) == %{
             "success" => true,
             "bank_id" => "foresight-floor",
             "items_count" => 1,
             "async" => false,
             "trace" => %{"timings_ms" => %{"total_ms" => 123}}
           }
  end

  test "recall_response preserves source_facts null when requested but absent" do
    payload = %{"query" => "hello", "include" => %{"source_facts" => %{}}}

    assert HindsightWire.recall_response(%{"results" => [], "source_facts" => nil}, payload) == %{
             "results" => [],
             "entities" => nil,
             "source_facts" => nil
           }
  end

  test "recall_response shapes source_facts as id-keyed recall results when requested" do
    payload = %{"query" => "hello", "include" => %{"source_facts" => %{}}}

    response =
      HindsightWire.recall_response(
        %{
          "results" => [],
          "source_facts" => %{
            "source-1" => %{
              "id" => "source-1",
              "content" => "source fact",
              "type" => "experience",
              "entities" => ["Fosferon"],
              "context" => "source",
              "mentioned_at" => "2026-06-01T09:00:00Z",
              "tags" => []
            }
          }
        },
        payload
      )

    assert response == %{
             "results" => [],
             "entities" => nil,
             "source_facts" => %{
               "source-1" => %{
                 "chunk_id" => nil,
                 "id" => "source-1",
                 "text" => "source fact",
                 "type" => "experience",
                 "entities" => ["Fosferon"],
                 "context" => "source",
                 "mentioned_at" => "2026-06-01T09:00:00Z",
                 "document_id" => nil,
                 "occurred_start" => nil,
                 "occurred_end" => nil,
                 "tags" => [],
                 "source_fact_ids" => nil
               }
             }
           }
  end

  test "normalize_file_retain_payload normalizes Plug.Upload entries and applies files_metadata" do
    path = Plug.Upload.random_file!("wire-upload")
    File.write!(path, "hello from upload")

    upload = %Plug.Upload{
      path: path,
      filename: "report.txt",
      content_type: "text/plain"
    }

    assert {:ok, payload} =
             HindsightWire.normalize_file_retain_payload(%{
               "files" => [upload],
               "request" =>
                 Jason.encode!(%{
                   "parser" => "markitdown",
                   "files_metadata" => [
                     %{
                       "document_id" => "doc-7",
                       "metadata" => %{"source" => "multipart-test"}
                     }
                   ]
                 })
             })

    assert payload == %{
             "files" => [
               %{
                 "path" => path,
                 "filename" => "report.txt",
                 "content_type" => "text/plain",
                 "document_id" => "doc-7",
                 "metadata" => %{"source" => "multipart-test"}
               }
             ],
             "request" => %{
               "parser" => "markitdown",
               "async" => true
             }
           }
  end

  test "normalize_recall_payload accepts min_score and still rejects pagination fields" do
    assert {:ok, %{"min_score" => 0.5}} =
             HindsightWire.normalize_recall_payload(%{"query" => "q", "min_score" => 0.5})

    assert {:error, %Foresight.Error{detail: %{message: message}}} =
             HindsightWire.normalize_recall_payload(%{"query" => "q", "limit" => 3})

    assert message =~ "limit is not part of hindsight's recall contract"
  end

  test "recall_response carries each result's score" do
    assert %{"results" => [%{"id" => "m1", "score" => 0.87}]} =
             HindsightWire.recall_response(
               %{
                 "results" => [%{"id" => "m1", "text" => "t", "type" => "world", "score" => 0.87}]
               },
               %{"query" => "q"}
             )
  end

  test "retain_response carries usage on a synchronous result only when present" do
    usage = %{
      "input_tokens" => 7,
      "output_tokens" => 3,
      "total_tokens" => 10,
      "failed_calls" => 0,
      "calls" => [%{"kind" => "llm", "role" => "extract", "provider" => "openai"}]
    }

    base = %{"success" => true, "bank_id" => "b", "items_count" => 1, "async" => false}

    assert %{"usage" => ^usage} = HindsightWire.retain_response(Map.put(base, "usage", usage))
    refute Map.has_key?(HindsightWire.retain_response(Map.put(base, "usage", nil)), "usage")
  end

  test "recall_response carries usage only when present" do
    usage = %{"input_tokens" => 4, "output_tokens" => 0, "total_tokens" => 4, "calls" => []}
    result = %{"results" => [%{"id" => "m1", "text" => "t", "type" => "world"}]}

    assert %{"usage" => ^usage} =
             HindsightWire.recall_response(Map.put(result, "usage", usage), %{"query" => "q"})

    refute Map.has_key?(HindsightWire.recall_response(result, %{"query" => "q"}), "usage")
  end

  test "retain_response passes the extraction report through" do
    extraction = %{
      "enabled" => true,
      "mode" => "concise",
      "fallback_items" => 1,
      "empty_items" => 0
    }

    assert %{"extraction" => ^extraction} =
             HindsightWire.retain_response(%{
               "success" => true,
               "bank_id" => "b",
               "items_count" => 1,
               "async" => false,
               "extraction" => extraction
             })
  end
end
