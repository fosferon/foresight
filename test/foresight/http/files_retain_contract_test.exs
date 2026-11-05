defmodule Foresight.HTTP.FilesRetainContractTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  defmodule CaptureBackend do
    @moduledoc false

    @behaviour Foresight.Backend

    defdelegate retain(ctx, payload, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate recall(ctx, payload, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate reflect(ctx, payload, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate consolidate(ctx, payload, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_memories(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate get_memory(ctx, memory_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_entities(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate entity_graph(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate get_entity(ctx, entity_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_tags(ctx, params, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate list_directives(ctx, bank_id, params, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate get_directive(ctx, bank_id, directive_id, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate create_directive(ctx, bank_id, attrs, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate update_directive(ctx, bank_id, directive_id, attrs, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate delete_directive(ctx, bank_id, directive_id, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate list_mental_models(ctx, bank_id, params, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate get_mental_model(ctx, bank_id, mental_model_id, params, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate get_mental_model_history(ctx, bank_id, mental_model_id, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate create_mental_model(ctx, bank_id, attrs, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate update_mental_model(ctx, bank_id, mental_model_id, attrs, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate delete_mental_model(ctx, bank_id, mental_model_id, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate refresh_mental_model(ctx, bank_id, mental_model_id, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate bank_profile(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_documents(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate get_document(ctx, document_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_audit_logs(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate audit_log_stats(ctx, params, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate memories_timeseries(ctx, bank_id, period, time_field, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate memory_graph(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate get_chunk(ctx, chunk_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_operations(ctx, params, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate get_operation(ctx, operation_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate cancel_operation(ctx, operation_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate retry_operation(ctx, operation_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate recover_consolidation(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_banks(ctx, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate put_bank(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate update_bank_disposition(ctx, bank_id, disposition, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate add_bank_background(ctx, bank_id, content, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate patch_bank(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate delete_bank(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate clear_bank_memories(ctx, bank_id, params, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate get_bank_config(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate update_bank_config(ctx, bank_id, updates, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate reset_bank_config(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate create_webhook(ctx, bank_id, attrs, opts), to: Foresight.TestSupport.RouterBackend
    defdelegate list_webhooks(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate update_webhook(ctx, bank_id, webhook_id, attrs, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate delete_webhook(ctx, bank_id, webhook_id, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate list_webhook_deliveries(ctx, bank_id, webhook_id, params, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate export_bank_template(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend

    defdelegate import_bank_template(ctx, bank_id, manifest, opts),
      to: Foresight.TestSupport.RouterBackend

    defdelegate bank_stats(ctx, bank_id, opts), to: Foresight.TestSupport.RouterBackend

    def retain_files(ctx, payload, _opts) do
      send(self(), {:captured_retain_files, ctx, payload})
      {:ok, %{"operation_ids" => ["file-op-capture"], "operation_id" => "file-op-capture"}}
    end
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end
    end)
  end

  test "JSON files/retain returns the hindsight-style async operation envelope" do
    Application.put_env(:foresight, :backend, Foresight.TestSupport.RouterBackend)

    conn =
      conn(
        :post,
        "/v1/default/banks/fosferon/files/retain",
        Jason.encode!(%{
          "files" => [%{"filename" => "report.pdf", "content_type" => "application/pdf"}],
          "request" => %{"parser" => "markitdown"}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> call_router()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"operation_ids" => ["file-op-1"]}
  end

  test "multipart files/retain preserves uploaded file metadata for backend ingestion" do
    Application.put_env(:foresight, :backend, CaptureBackend)

    path = Plug.Upload.random_file!("files-retain-parity")
    File.write!(path, "multipart file body")

    boundary = "----foresight-multipart-boundary"

    body =
      multipart_body(boundary, [
        {:file, "files", path, "report.txt", "text/plain"},
        {:field, "request",
         Jason.encode!(%{
           "parser" => "markitdown",
           "files_metadata" => [
             %{
               "document_id" => "doc-multipart",
               "metadata" => %{"source" => "contract-test"}
             }
           ]
         })}
      ])

    conn =
      conn(:post, "/v1/default/banks/fosferon/files/retain", body)
      |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
      |> call_router()

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"operation_ids" => ["file-op-capture"]}

    assert_receive {:captured_retain_files, ctx, payload}
    assert ctx.bank == "fosferon"

    assert %{"request" => %{"parser" => "markitdown", "async" => true}, "files" => [file]} =
             payload

    assert file["filename"] == "report.txt"
    assert file["content_type"] == "text/plain"
    assert file["document_id"] == "doc-multipart"
    assert file["metadata"] == %{"source" => "contract-test"}
    assert is_binary(file["path"])
    assert File.exists?(file["path"])
  end

  test "files/retain rejects files_metadata count drift" do
    Application.put_env(:foresight, :backend, Foresight.TestSupport.RouterBackend)

    conn =
      conn(
        :post,
        "/v1/default/banks/fosferon/files/retain",
        Jason.encode!(%{
          "files" => [
            %{"filename" => "report-a.pdf"},
            %{"filename" => "report-b.pdf"}
          ],
          "request" => %{
            "files_metadata" => [%{"document_id" => "doc-1"}]
          }
        })
      )
      |> put_req_header("content-type", "application/json")
      |> call_router()

    assert conn.status == 400

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "invalid_request",
             "detail" => %{
               "message" => "files_metadata count must match uploaded files count"
             }
           }
  end

  defp call_router(conn) do
    Foresight.HTTP.Router.call(
      conn,
      Foresight.HTTP.Router.init(
        config: %{
          auth: %{api_key: nil},
          file_ingestion: %{enabled: true},
          http: %{enabled: true},
          health: %{checker: Foresight.Health},
          ml: %{enabled: false},
          oban: %{enabled: false},
          repo: %{enabled: false}
        }
      )
    )
  end

  defp multipart_body(boundary, parts) do
    parts
    |> Enum.map_join(fn part -> multipart_part(boundary, part) end)
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
