defmodule Foresight.Backend.Store do
  @moduledoc false

  @behaviour Foresight.Backend

  alias Foresight.Context
  alias Foresight.Error

  @impl true
  def retain(%Context{} = ctx, payload, opts),
    do: storage().retain(ctx, payload, merge_opts(opts))

  @impl true
  def retain_files(%Context{} = ctx, payload, opts) do
    request = Map.get(payload, "request", %{})

    with {:ok, items} <- convert_files(payload["files"] || [], request, opts) do
      # ASYNC DEFAULTS DIVERGE BY SURFACE, DELIBERATELY.
      #
      # Here (file retain, REST) the default is TRUE: it matches Hindsight, whose retain is
      # async-by-default and returns operation ids, and file-heavy consumers depend on
      # retain returning promptly rather than blocking on embedding and extraction for a
      # whole file.
      #
      # The MCP face defaults to FALSE instead — see Foresight.MCP.Tools.dispatch/3 — because
      # mcp can be enabled without oban, where an async default could never complete.
      #
      # The divergence is the deployment constraint, not an oversight, and both defaults are
      # pinned by tests. If a queue is genuinely absent, the enqueue now answers :unavailable
      # rather than raising (Foresight.AsyncQueues.Oban).
      retain_payload = %{
        "items" => items,
        "async" => Map.get(request, "async", true)
      }

      with {:ok, retain_result} <- storage().retain(ctx, retain_payload, merge_opts(opts)) do
        {:ok,
         %{
           "operation_ids" => file_operation_ids(retain_result),
           "operation_id" => retain_result["operation_id"]
         }}
      end
    end
  end

  @impl true
  def recall(%Context{} = ctx, payload, opts),
    do: storage().recall(ctx, payload, merge_opts(opts))

  @impl true
  def reflect(%Context{} = ctx, payload, opts),
    do: storage().reflect(ctx, payload, merge_opts(opts))

  @impl true
  def consolidate(%Context{} = ctx, payload, opts),
    do: storage().consolidate(ctx, payload, merge_opts(opts))

  @impl true
  def list_banks(%Context{} = ctx, opts), do: storage().list_banks(ctx, merge_opts(opts))

  @impl true
  def put_bank(%Context{} = ctx, bank_id, attrs, opts),
    do: storage().put_bank(ctx, bank_id, attrs, merge_opts(opts))

  @impl true
  def patch_bank(%Context{} = ctx, bank_id, attrs, opts),
    do: storage().patch_bank(ctx, bank_id, attrs, merge_opts(opts))

  @impl true
  def update_bank_disposition(%Context{} = ctx, bank_id, disposition, opts),
    do: storage().update_bank_disposition(ctx, bank_id, disposition, merge_opts(opts))

  @impl true
  def add_bank_background(%Context{} = ctx, bank_id, content, opts),
    do: storage().add_bank_background(ctx, bank_id, content, merge_opts(opts))

  @impl true
  def delete_bank(%Context{} = ctx, bank_id, opts),
    do: storage().delete_bank(ctx, bank_id, merge_opts(opts))

  @impl true
  def clear_bank_memories(%Context{} = ctx, bank_id, params, opts),
    do: storage().clear_bank_memories(ctx, bank_id, params, merge_opts(opts))

  @impl true
  def get_bank_config(%Context{} = ctx, bank_id, opts),
    do: storage().get_bank_config(ctx, bank_id, merge_opts(opts))

  @impl true
  def update_bank_config(%Context{} = ctx, bank_id, updates, opts),
    do: storage().update_bank_config(ctx, bank_id, updates, merge_opts(opts))

  @impl true
  def reset_bank_config(%Context{} = ctx, bank_id, opts),
    do: storage().reset_bank_config(ctx, bank_id, merge_opts(opts))

  @impl true
  def create_webhook(%Context{} = ctx, bank_id, attrs, opts),
    do: storage().create_webhook(ctx, bank_id, attrs, merge_opts(opts))

  @impl true
  def list_webhooks(%Context{} = ctx, bank_id, opts),
    do: storage().list_webhooks(ctx, bank_id, merge_opts(opts))

  @impl true
  def update_webhook(%Context{} = ctx, bank_id, webhook_id, attrs, opts),
    do: storage().update_webhook(ctx, bank_id, webhook_id, attrs, merge_opts(opts))

  @impl true
  def delete_webhook(%Context{} = ctx, bank_id, webhook_id, opts),
    do: storage().delete_webhook(ctx, bank_id, webhook_id, merge_opts(opts))

  @impl true
  def list_webhook_deliveries(%Context{} = ctx, bank_id, webhook_id, params, opts),
    do: storage().list_webhook_deliveries(ctx, bank_id, webhook_id, params, merge_opts(opts))

  @impl true
  def export_bank_template(%Context{} = ctx, bank_id, opts),
    do: storage().export_bank_template(ctx, bank_id, merge_opts(opts))

  @impl true
  def import_bank_template(%Context{} = ctx, bank_id, manifest, opts),
    do: storage().import_bank_template(ctx, bank_id, manifest, merge_opts(opts))

  @impl true
  def bank_stats(%Context{} = ctx, bank_id, opts),
    do: storage().bank_stats(ctx, bank_id, merge_opts(opts))

  @impl true
  def memories_timeseries(%Context{} = ctx, bank_id, period, time_field, opts),
    do: storage().memories_timeseries(ctx, bank_id, period, time_field, merge_opts(opts))

  @impl true
  def list_memories(%Context{} = ctx, params, opts),
    do: storage().list_memories(ctx, params, merge_opts(opts))

  @impl true
  def get_memory(%Context{} = ctx, memory_id, opts),
    do: storage().get_memory(ctx, memory_id, merge_opts(opts))

  @impl true
  def get_memory_history(%Context{} = ctx, memory_id, opts),
    do: storage().get_memory_history(ctx, memory_id, merge_opts(opts))

  @impl true
  def delete_memory(%Context{} = ctx, bank_id, memory_id, opts),
    do: storage().delete_memory(ctx, bank_id, memory_id, merge_opts(opts))

  @impl true
  def list_entities(%Context{} = ctx, params, opts),
    do: storage().list_entities(ctx, params, merge_opts(opts))

  @impl true
  def entity_graph(%Context{} = ctx, params, opts),
    do: storage().entity_graph(ctx, params, merge_opts(opts))

  @impl true
  def get_entity(%Context{} = ctx, entity_id, opts),
    do: storage().get_entity(ctx, entity_id, merge_opts(opts))

  @impl true
  def list_tags(%Context{} = ctx, params, opts),
    do: storage().list_tags(ctx, params, merge_opts(opts))

  @impl true
  def list_directives(%Context{} = ctx, bank_id, params, opts),
    do: storage().list_directives(ctx, bank_id, params, merge_opts(opts))

  @impl true
  def get_directive(%Context{} = ctx, bank_id, directive_id, opts),
    do: storage().get_directive(ctx, bank_id, directive_id, merge_opts(opts))

  @impl true
  def create_directive(%Context{} = ctx, bank_id, attrs, opts),
    do: storage().create_directive(ctx, bank_id, attrs, merge_opts(opts))

  @impl true
  def update_directive(%Context{} = ctx, bank_id, directive_id, attrs, opts),
    do: storage().update_directive(ctx, bank_id, directive_id, attrs, merge_opts(opts))

  @impl true
  def delete_directive(%Context{} = ctx, bank_id, directive_id, opts),
    do: storage().delete_directive(ctx, bank_id, directive_id, merge_opts(opts))

  @impl true
  def list_mental_models(%Context{} = ctx, bank_id, params, opts),
    do: storage().list_mental_models(ctx, bank_id, params, merge_opts(opts))

  @impl true
  def get_mental_model(%Context{} = ctx, bank_id, mental_model_id, params, opts),
    do: storage().get_mental_model(ctx, bank_id, mental_model_id, params, merge_opts(opts))

  @impl true
  def get_mental_model_history(%Context{} = ctx, bank_id, mental_model_id, opts),
    do: storage().get_mental_model_history(ctx, bank_id, mental_model_id, merge_opts(opts))

  @impl true
  def create_mental_model(%Context{} = ctx, bank_id, attrs, opts),
    do: storage().create_mental_model(ctx, bank_id, attrs, merge_opts(opts))

  @impl true
  def update_mental_model(%Context{} = ctx, bank_id, mental_model_id, attrs, opts),
    do: storage().update_mental_model(ctx, bank_id, mental_model_id, attrs, merge_opts(opts))

  @impl true
  def delete_mental_model(%Context{} = ctx, bank_id, mental_model_id, opts),
    do: storage().delete_mental_model(ctx, bank_id, mental_model_id, merge_opts(opts))

  @impl true
  def refresh_mental_model(%Context{} = ctx, bank_id, mental_model_id, opts),
    do: storage().refresh_mental_model(ctx, bank_id, mental_model_id, merge_opts(opts))

  @impl true
  def bank_profile(%Context{} = ctx, bank_id, opts),
    do: storage().bank_profile(ctx, bank_id, merge_opts(opts))

  @impl true
  def list_documents(%Context{} = ctx, params, opts),
    do: storage().list_documents(ctx, params, merge_opts(opts))

  @impl true
  def get_document(%Context{} = ctx, document_id, opts),
    do: storage().get_document(ctx, document_id, merge_opts(opts))

  @impl true
  def list_document_chunks(%Context{} = ctx, document_id, params, opts),
    do: storage().list_document_chunks(ctx, document_id, params, merge_opts(opts))

  @impl true
  def list_audit_logs(%Context{} = ctx, params, opts),
    do: storage().list_audit_logs(ctx, params, merge_opts(opts))

  @impl true
  def audit_log_stats(%Context{} = ctx, params, opts),
    do: storage().audit_log_stats(ctx, params, merge_opts(opts))

  @impl true
  def update_document(%Context{} = ctx, bank_id, document_id, attrs, opts),
    do: storage().update_document(ctx, bank_id, document_id, attrs, merge_opts(opts))

  @impl true
  def delete_document(%Context{} = ctx, bank_id, document_id, opts),
    do: storage().delete_document(ctx, bank_id, document_id, merge_opts(opts))

  @impl true
  def reprocess_document(%Context{} = ctx, bank_id, document_id, opts),
    do: storage().reprocess_document(ctx, bank_id, document_id, merge_opts(opts))

  @impl true
  def memory_graph(%Context{} = ctx, params, opts),
    do: storage().memory_graph(ctx, params, merge_opts(opts))

  @impl true
  def get_chunk(%Context{} = ctx, chunk_id, opts),
    do: storage().get_chunk(ctx, chunk_id, merge_opts(opts))

  @impl true
  def list_operations(%Context{} = ctx, params, opts),
    do: storage().list_operations(ctx, params, merge_opts(opts))

  @impl true
  def get_operation(%Context{} = ctx, operation_id, opts),
    do: storage().get_operation(ctx, operation_id, merge_opts(opts))

  @impl true
  def cancel_operation(%Context{} = ctx, operation_id, opts),
    do: storage().cancel_operation(ctx, operation_id, merge_opts(opts))

  @impl true
  def retry_operation(%Context{} = ctx, operation_id, opts),
    do: storage().retry_operation(ctx, operation_id, merge_opts(opts))

  @impl true
  def recover_consolidation(%Context{} = ctx, bank_id, opts),
    do: storage().recover_consolidation(ctx, bank_id, merge_opts(opts))

  @impl true
  def clear_observations(%Context{} = ctx, bank_id, opts),
    do: storage().clear_observations(ctx, bank_id, merge_opts(opts))

  @impl true
  def clear_memory_observations(%Context{} = ctx, bank_id, memory_id, opts),
    do: storage().clear_memory_observations(ctx, bank_id, memory_id, merge_opts(opts))

  defp storage do
    engine_config().storage
  end

  defp convert_files(files, request, opts) do
    converter_opts =
      file_ingestion_config().converter_opts
      |> List.wrap()
      |> Keyword.merge(opts)

    files
    |> Enum.map(&normalize_file/1)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, items} ->
      case converter_for(file, converter_opts).convert(file, converter_opts) do
        {:ok, conversion} ->
          case build_retain_items(file, conversion, request, index) do
            {:ok, file_items} ->
              {:cont, {:ok, items ++ file_items}}

            {:error, %Error{} = error} ->
              {:halt, {:error, error}}
          end

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        {:error, reason} ->
          {:halt, {:error, Error.new(:not_implemented, %{message: inspect(reason)})}}
      end
    end)
  end

  # Structure-preserving ingestion: when docling exposed document structure, emit
  # one retain item per structural chunk, each carrying its own source_location, so
  # every resulting memory unit knows exactly where in the source document it came
  # from. All chunks share one document_id (→ document_ref); the original file bytes
  # are attached to the FIRST chunk only (upsert dedups the Document + file storage
  # by document_id, so bytes are stored once rather than per chunk). When docling
  # produced only flat markdown, fall back to a single whole-document item.
  defp build_retain_items(file, conversion, request, index) do
    request_metadata = Map.get(request, "metadata", %{})
    file_metadata = Map.get(file, "metadata", %{})

    with {:ok, file_attrs} <- file_attrs(file, conversion) do
      document_id =
        Enum.find([file["document_id"], file["filename"]], &(not blank_id?(&1))) ||
          "file-#{index}"

      base = %{
        "context" => Map.get(request, "context", "file"),
        "type" => Map.get(request, "type", "document"),
        "document_id" => document_id,
        "document_title" => conversion[:title] || file["filename"],
        "document_text" => conversion[:text],
        "metadata" =>
          request_metadata
          |> Map.merge(file_metadata)
          |> Map.merge(Map.get(conversion, :metadata, %{}))
          |> maybe_put("filename", file["filename"])
          |> maybe_put("content_type", file["content_type"] || conversion[:content_type]),
        "tags" => Map.get(request, "tags", [])
      }

      {:ok, chunk_items(conversion, maybe_put_update_mode(base, file, request), file_attrs)}
    end
  end

  defp chunk_items(conversion, base, file_attrs) do
    case structural_chunks(conversion) do
      [] ->
        [base |> Map.put("content", conversion[:text]) |> Map.merge(file_attrs)]

      chunks ->
        chunks
        |> Enum.with_index()
        |> Enum.map(fn {chunk, chunk_index} ->
          item =
            base
            |> Map.put("content", chunk_text(chunk))
            |> Map.put("source_location", chunk_source_location(chunk))

          if chunk_index == 0, do: Map.merge(item, file_attrs), else: item
        end)
    end
  end

  defp structural_chunks(conversion) do
    conversion
    |> Map.get(:chunks, [])
    |> List.wrap()
    |> Enum.filter(&retainable_chunk?/1)
  end

  # Mirror extract_retain_item's content filter (retain drops items with no
  # alphanumeric content). Applying it here guarantees the FIRST emitted chunk —
  # which carries the original file bytes + storage key — actually survives
  # extraction, so the document→file provenance link is never silently orphaned by
  # a symbol-only leading chunk. If nothing survives, build_retain_items falls back
  # to the whole-document item.
  defp retainable_chunk?(chunk) do
    text = is_map(chunk) and chunk_text(chunk)
    is_binary(text) and Regex.match?(~r/[[:alnum:]]/u, text)
  end

  defp chunk_text(chunk), do: chunk["text"] || chunk[:text]

  # The chunk's provenance, minus the raw text — page / section path / element type
  # / bbox / char span — stored as the memory unit's source_location.
  defp chunk_source_location(chunk) do
    chunk
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["text"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp merge_opts(opts) do
    Keyword.merge(
      [
        repo: engine_config().repo,
        embedder: engine_config().embedder,
        reranker: engine_config().reranker,
        llm: engine_config().llm,
        queue: engine_config().queue,
        oban_name: engine_config().oban_name,
        reranker_serving_name: engine_config().reranker_serving_name,
        reflect_max_iterations: engine_config().reflect_max_iterations,
        reflect_min_grounding_count: engine_config().reflect_min_grounding_count,
        reflect_min_diverse_grounding_count: engine_config().reflect_min_diverse_grounding_count,
        reflect_min_provenance_cluster_count:
          engine_config().reflect_min_provenance_cluster_count,
        reflect_min_source_provenance_cluster_count:
          engine_config().reflect_min_source_provenance_cluster_count,
        reflect_min_source_family_count: engine_config().reflect_min_source_family_count,
        reflect_min_source_lineage_count: engine_config().reflect_min_source_lineage_count,
        reflect_min_evidence_family_count: engine_config().reflect_min_evidence_family_count,
        reflect_max_context_tokens: engine_config().reflect_max_context_tokens,
        reflect_timeout_ms: engine_config().reflect_timeout_ms,
        retain_extraction_mode: Map.get(engine_config(), :retain_extraction_mode),
        retain_extraction_mission: Map.get(engine_config(), :retain_extraction_mission),
        retain_extraction_instructions: Map.get(engine_config(), :retain_extraction_instructions),
        retain_extraction_deadline_ms: Map.get(engine_config(), :retain_extraction_deadline_ms),
        retain_extraction_concurrency: Map.get(engine_config(), :retain_extraction_concurrency),
        retain_extraction_provider_opts:
          Map.get(engine_config(), :retain_extraction_provider_opts),
        consolidation_provider_opts: Map.get(engine_config(), :consolidation_provider_opts),
        entity_extractor:
          Map.get(engine_config(), :entity_extractor, Foresight.EntityExtractors.Simple),
        sleep_ms: Map.get(engine_config(), :sleep_ms)
      ],
      opts
    )
  end

  defp engine_config do
    %{
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      reranker: Foresight.Rerankers.Passthrough,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.AsyncQueues.Oban,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing,
      reflect_max_iterations: 10,
      reflect_min_grounding_count: 1,
      reflect_min_diverse_grounding_count: 1,
      reflect_min_provenance_cluster_count: 1,
      reflect_min_source_provenance_cluster_count: 0,
      reflect_min_source_family_count: 0,
      reflect_min_source_lineage_count: 0,
      reflect_min_evidence_family_count: 0,
      reflect_max_context_tokens: 100_000,
      reflect_timeout_ms: 120_000
    }
    |> Map.merge(
      Application.get_env(:foresight, :engine, %{})
      |> Enum.into(%{})
    )
  end

  defp file_ingestion_config do
    %{
      enabled: false,
      converter: Foresight.DocumentConverters.Docling,
      converter_opts: [],
      worker: Foresight.Ingestion.DoclingWorker
    }
    |> Map.merge(
      Application.get_env(:foresight, :file_ingestion, %{})
      |> Enum.into(%{})
    )
  end

  defp document_converter(opts),
    do: Keyword.get(opts, :document_converter, file_ingestion_config().converter)

  # A text body needs no conversion, so it bypasses the configured converter. A bare
  # binary gets a content-addressed document_id: the positional "file-N" fallback would
  # make every single-file call collide on "file-0".
  defp converter_for(%{"text" => _}, opts) do
    Keyword.get(opts, :text_converter, Foresight.DocumentConverters.Text)
  end

  defp converter_for(_file, opts), do: document_converter(opts)

  defp normalize_file(text) when is_binary(text),
    do: normalize_file(%{"text" => text})

  defp normalize_file(%{"text" => text} = file) when is_binary(text) do
    if blank_id?(file["document_id"]) and blank_id?(file["filename"]) do
      digest = :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
      Map.put(file, "document_id", "text:" <> digest)
    else
      file
    end
  end

  defp normalize_file(file), do: file

  # JSON clients send explicit nulls and empty strings; both mean "no id given".
  defp blank_id?(value), do: value in [nil, ""]

  defp file_operation_ids(%{"operation_ids" => operation_ids}) when is_list(operation_ids),
    do: operation_ids

  defp file_operation_ids(%{"operation_id" => operation_id}) when is_binary(operation_id),
    do: [operation_id]

  defp file_operation_ids(_result), do: []

  defp file_attrs(file, conversion) do
    case file_bytes(file) do
      {:ok, nil} ->
        {:ok, %{}}

      {:ok, data} ->
        storage_key = file["file_storage_key"] || default_file_storage_key(file, data)

        {:ok,
         %{
           "file_storage_key" => storage_key,
           "file_original_name" => file["filename"],
           "file_content_type" => file["content_type"] || conversion[:content_type],
           "file_storage_data" => data
         }}

      {:error, reason} ->
        {:error, Error.new(:invalid_request, %{message: reason})}
    end
  end

  defp file_bytes(%{"store_file" => false}), do: {:ok, nil}
  defp file_bytes(%{"text" => _}), do: {:ok, nil}

  defp file_bytes(%{"path" => path}) when is_binary(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "failed to read uploaded file: #{inspect(reason)}"}
    end
  end

  defp file_bytes(_file), do: {:ok, nil}

  defp default_file_storage_key(file, data) do
    digest =
      :sha256
      |> :crypto.hash(data)
      |> Base.encode16(case: :lower)

    ["file", file["document_id"] || file["filename"] || "upload", digest]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  # Opt-in only, matching Hindsight: by default a re-retained document_id appends a
  # second set of memory units; "replace" deletes the prior set first (and retracts
  # only those units' entity mentions).
  defp maybe_put_update_mode(item, file, request),
    do: maybe_put(item, "update_mode", file["update_mode"] || Map.get(request, "update_mode"))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
