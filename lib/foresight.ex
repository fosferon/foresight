defmodule Foresight do
  @moduledoc """
  Semantic memory: retain what happened, recall what is relevant, reflect to answer.

  This module is the public API. Every function takes a `Foresight.Context` naming
  the tenant, isolation mode and bank, so no call can touch memory without saying
  whose memory it is — there is no ambient state and no "current bank".

      ctx = %Foresight.Context{tenant_id: "default", mode: :mode_a, bank: "notes"}

      Foresight.retain(ctx, %{"items" => [%{"content" => "Maria leads the payments migration."}]})
      Foresight.reflect(ctx, %{"query" => "who owns payments?"})

  ## The three verbs

  `retain/3` is not an insert. It extracts discrete dated facts from what you give
  it, embeds them, and links entities into a graph. One paragraph usually becomes
  several independently retrievable facts, and it costs an LLM call.

  `recall/3` retrieves and ranks. It does not interpret. Use it when your own code
  decides what the results mean.

  `reflect/3` answers. A model searches memory itself, in a loop, choosing what to
  look for next from what it has already found. Use it when the answer has to be
  assembled from several places.

  The gap between the last two is large: on the project benchmark, reflect scores
  0.833 against a fixed reader's 0.467 over identical memories (McNemar p = 0.001).

  ## Return values

  Every function returns `{:ok, result}` or `{:error, %Foresight.Error{}}`. The
  error struct carries a `:reason` atom you can match on, so a missing capability
  is distinguishable from a bad request without parsing strings:

      case Foresight.reflect(ctx, %{"query" => q}) do
        {:ok, answer} -> answer
        {:error, %Foresight.Error{reason: :unavailable}} -> :degraded
        {:error, %Foresight.Error{reason: :invalid_request, detail: d}} -> {:bad, d}
      end

  ## Guides

  Start with [Overview](overview.md), then [Getting started](getting-started.md).
  [How recall works](how-recall-works.md) explains the ranking and is worth reading
  before tuning anything.
  """

  alias Foresight.Backend
  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.Migration.BankMigrator

  @doc """
  Store something that happened, extracting facts from it.

  `payload` carries an `"items"` list; each item needs `"content"` and may carry
  `"context"`, `"type"`, `"tags"` and `"metadata"`.

      Foresight.retain(ctx, %{
        "items" => [
          %{"content" => "Deployed v2.3 on Tuesday; the migration took 40 minutes.",
            "context" => "ops log",
            "tags" => ["deploy"]}
        ]
      })

  Pass `"async" => true` to queue the work instead of running it inline — this
  requires Oban, and returns an operation id you can poll with
  `get_operation/3`. Without Oban you get `{:error, %Foresight.Error{reason:
  :unavailable}}` rather than a crash.

  Extraction quality dominates answer quality downstream. If answers are poor,
  inspect what was actually stored with `list_memories/3` before tuning retrieval.
  """
  @spec retain(Context.t(), term(), keyword()) :: Backend.result()
  def retain(%Context{} = ctx, payload, opts \\ []) do
    backend().retain(ctx, payload, opts)
  end

  @spec retain_files(Context.t(), term(), keyword()) :: Backend.result()
  def retain_files(%Context{} = ctx, payload, opts \\ []) do
    backend().retain_files(ctx, payload, opts)
  end

  @doc """
  Retrieve memories relevant to a query, ranked.

      {:ok, %{"results" => results}} = Foresight.recall(ctx, %{"query" => "payments migration"})

  Four searches run concurrently — semantic, keyword, graph and temporal — and are
  merged into one ranking. See [How recall works](how-recall-works.md) for the
  merge, which matters more than most of the searches.

  Useful keys: `"max_tokens"` to budget the result set, `"types"` to restrict to
  e.g. `["observation"]`, and `"trace" => true` to get a full explanation of the
  ranking including per-stage `timings_ms`.
  """
  @spec recall(Context.t(), term(), keyword()) :: Backend.result()
  def recall(%Context{} = ctx, query, opts \\ []) do
    backend().recall(ctx, query, opts)
  end

  @doc """
  Answer a question from memory, searching iteratively.

      {:ok, answer} = Foresight.reflect(ctx, %{"query" => "why did the migration slip?"})

  Requires an LLM. The model is given tools — `recall`, `search_observations`,
  `search_mental_models`, `expand` — and decides for itself what to look for next.

  Check `trace["mode"]` when the results disappoint: `"agentic"` means the loop
  ran, `"fixed"` means the configured model cannot call tools and Foresight fell
  back to a single-pass pipeline. The fallback is silent by design, which makes it
  easy to mistake for the loop underperforming. See [Reflect](reflect.md).
  """
  @spec reflect(Context.t(), term(), keyword()) :: Backend.result()
  def reflect(%Context{} = ctx, query, opts \\ []) do
    backend().reflect(ctx, query, opts)
  end

  @doc """
  Merge related facts into durable observations.

  Runs during `retain/3`; call it directly to consolidate a bank on demand.
  Observations are what `search_observations` reads during `reflect/3` — the
  difference between assembling an answer from twenty fragments and drawing it
  from one settled statement.
  """
  @spec consolidate(Context.t(), term(), keyword()) :: Backend.result()
  def consolidate(%Context{} = ctx, payload \\ %{}, opts \\ []) do
    backend().consolidate(ctx, payload, opts)
  end

  @spec list_banks(Context.t(), keyword()) :: Backend.result()
  def list_banks(%Context{} = ctx, opts \\ []) do
    backend().list_banks(ctx, opts)
  end

  @spec put_bank(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def put_bank(%Context{} = ctx, bank_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_map(attrs) do
    backend().put_bank(ctx, bank_id, attrs, opts)
  end

  @spec patch_bank(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def patch_bank(%Context{} = ctx, bank_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_map(attrs) do
    backend().patch_bank(ctx, bank_id, attrs, opts)
  end

  @spec update_bank_disposition(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def update_bank_disposition(%Context{} = ctx, bank_id, disposition, opts \\ [])
      when is_binary(bank_id) and is_map(disposition) do
    backend().update_bank_disposition(ctx, bank_id, disposition, opts)
  end

  @spec add_bank_background(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def add_bank_background(%Context{} = ctx, bank_id, content, opts \\ [])
      when is_binary(bank_id) and is_binary(content) do
    backend().add_bank_background(ctx, bank_id, content, opts)
  end

  @spec delete_bank(Context.t(), String.t(), keyword()) :: Backend.result()
  def delete_bank(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().delete_bank(ctx, bank_id, opts)
  end

  @spec clear_bank_memories(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def clear_bank_memories(%Context{} = ctx, bank_id, params \\ %{}, opts \\ [])
      when is_binary(bank_id) and is_map(params) do
    backend().clear_bank_memories(ctx, bank_id, params, opts)
  end

  @spec get_bank_config(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_bank_config(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().get_bank_config(ctx, bank_id, opts)
  end

  @spec update_bank_config(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def update_bank_config(%Context{} = ctx, bank_id, updates, opts \\ [])
      when is_binary(bank_id) and is_map(updates) do
    backend().update_bank_config(ctx, bank_id, updates, opts)
  end

  @spec reset_bank_config(Context.t(), String.t(), keyword()) :: Backend.result()
  def reset_bank_config(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().reset_bank_config(ctx, bank_id, opts)
  end

  @spec create_webhook(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def create_webhook(%Context{} = ctx, bank_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_map(attrs) do
    backend().create_webhook(ctx, bank_id, attrs, opts)
  end

  @spec list_webhooks(Context.t(), String.t(), keyword()) :: Backend.result()
  def list_webhooks(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().list_webhooks(ctx, bank_id, opts)
  end

  @spec update_webhook(Context.t(), String.t(), String.t(), map(), keyword()) :: Backend.result()
  def update_webhook(%Context{} = ctx, bank_id, webhook_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_binary(webhook_id) and is_map(attrs) do
    backend().update_webhook(ctx, bank_id, webhook_id, attrs, opts)
  end

  @spec delete_webhook(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def delete_webhook(%Context{} = ctx, bank_id, webhook_id, opts \\ [])
      when is_binary(bank_id) and is_binary(webhook_id) do
    backend().delete_webhook(ctx, bank_id, webhook_id, opts)
  end

  @spec list_webhook_deliveries(Context.t(), String.t(), String.t(), map(), keyword()) ::
          Backend.result()
  def list_webhook_deliveries(%Context{} = ctx, bank_id, webhook_id, params \\ %{}, opts \\ [])
      when is_binary(bank_id) and is_binary(webhook_id) and is_map(params) do
    backend().list_webhook_deliveries(ctx, bank_id, webhook_id, params, opts)
  end

  @spec export_bank_template(Context.t(), String.t(), keyword()) :: Backend.result()
  def export_bank_template(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().export_bank_template(ctx, bank_id, opts)
  end

  @spec import_bank_template(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def import_bank_template(%Context{} = ctx, bank_id, manifest, opts \\ [])
      when is_binary(bank_id) and is_map(manifest) do
    backend().import_bank_template(ctx, bank_id, manifest, opts)
  end

  @spec bank_stats(Context.t(), String.t(), keyword()) :: Backend.result()
  def bank_stats(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().bank_stats(ctx, bank_id, opts)
  end

  @spec memories_timeseries(Context.t(), String.t(), String.t(), String.t(), keyword()) ::
          Backend.result()
  def memories_timeseries(
        %Context{} = ctx,
        bank_id,
        period \\ "7d",
        time_field \\ "created_at",
        opts \\ []
      )
      when is_binary(bank_id) and is_binary(period) and is_binary(time_field) do
    backend().memories_timeseries(ctx, bank_id, period, time_field, opts)
  end

  @spec list_memories(Context.t(), map(), keyword()) :: Backend.result()
  def list_memories(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().list_memories(ctx, params, opts)
  end

  @spec get_memory(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_memory(%Context{} = ctx, memory_id, opts \\ []) when is_binary(memory_id) do
    backend().get_memory(ctx, memory_id, opts)
  end

  @spec get_memory_history(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_memory_history(%Context{} = ctx, memory_id, opts \\ []) when is_binary(memory_id) do
    backend().get_memory_history(ctx, memory_id, opts)
  end

  @doc """
  Delete one memory unit from `bank_id`.

  A Foresight extension: Hindsight only clears a whole bank or deletes a document.
  Deleting a source fact also deletes the observations consolidated from it and
  marks their other source facts for reconsolidation; deleting an observation marks
  its source facts for reconsolidation. Entity mention counts are retracted and the
  unit's links are removed. The operation is recorded in the mutation audit log.

  Returns `{:ok, %{"success" => true, "memory_id" => id, "memory_units_deleted" => n,
  "observations_deleted" => m}}`, or `{:error, %Foresight.Error{reason: :not_found}}`
  when no unit with that id exists in the bank.
  """
  @spec delete_memory(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def delete_memory(%Context{} = ctx, bank_id, memory_id, opts \\ [])
      when is_binary(bank_id) and is_binary(memory_id) do
    backend().delete_memory(ctx, bank_id, memory_id, opts)
  end

  @spec list_entities(Context.t(), map(), keyword()) :: Backend.result()
  def list_entities(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().list_entities(ctx, params, opts)
  end

  @spec entity_graph(Context.t(), map(), keyword()) :: Backend.result()
  def entity_graph(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().entity_graph(ctx, params, opts)
  end

  @spec get_entity(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_entity(%Context{} = ctx, entity_id, opts \\ []) when is_binary(entity_id) do
    backend().get_entity(ctx, entity_id, opts)
  end

  @spec list_tags(Context.t(), map(), keyword()) :: Backend.result()
  def list_tags(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().list_tags(ctx, params, opts)
  end

  @spec list_directives(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def list_directives(%Context{} = ctx, bank_id, params \\ %{}, opts \\ [])
      when is_binary(bank_id) and is_map(params) do
    backend().list_directives(ctx, bank_id, params, opts)
  end

  @spec get_directive(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def get_directive(%Context{} = ctx, bank_id, directive_id, opts \\ [])
      when is_binary(bank_id) and is_binary(directive_id) do
    backend().get_directive(ctx, bank_id, directive_id, opts)
  end

  @spec create_directive(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def create_directive(%Context{} = ctx, bank_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_map(attrs) do
    backend().create_directive(ctx, bank_id, attrs, opts)
  end

  @spec update_directive(Context.t(), String.t(), String.t(), map(), keyword()) ::
          Backend.result()
  def update_directive(%Context{} = ctx, bank_id, directive_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_binary(directive_id) and is_map(attrs) do
    backend().update_directive(ctx, bank_id, directive_id, attrs, opts)
  end

  @spec delete_directive(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def delete_directive(%Context{} = ctx, bank_id, directive_id, opts \\ [])
      when is_binary(bank_id) and is_binary(directive_id) do
    backend().delete_directive(ctx, bank_id, directive_id, opts)
  end

  @spec list_mental_models(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def list_mental_models(%Context{} = ctx, bank_id, params \\ %{}, opts \\ [])
      when is_binary(bank_id) and is_map(params) do
    backend().list_mental_models(ctx, bank_id, params, opts)
  end

  @spec get_mental_model(Context.t(), String.t(), String.t(), map(), keyword()) ::
          Backend.result()
  def get_mental_model(%Context{} = ctx, bank_id, mental_model_id, params \\ %{}, opts \\ [])
      when is_binary(bank_id) and is_binary(mental_model_id) and is_map(params) do
    backend().get_mental_model(ctx, bank_id, mental_model_id, params, opts)
  end

  @spec get_mental_model_history(Context.t(), String.t(), String.t(), keyword()) ::
          Backend.result()
  def get_mental_model_history(%Context{} = ctx, bank_id, mental_model_id, opts \\ [])
      when is_binary(bank_id) and is_binary(mental_model_id) do
    backend().get_mental_model_history(ctx, bank_id, mental_model_id, opts)
  end

  @spec create_mental_model(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def create_mental_model(%Context{} = ctx, bank_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_map(attrs) do
    backend().create_mental_model(ctx, bank_id, attrs, opts)
  end

  @spec update_mental_model(Context.t(), String.t(), String.t(), map(), keyword()) ::
          Backend.result()
  def update_mental_model(%Context{} = ctx, bank_id, mental_model_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_binary(mental_model_id) and is_map(attrs) do
    backend().update_mental_model(ctx, bank_id, mental_model_id, attrs, opts)
  end

  @spec delete_mental_model(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def delete_mental_model(%Context{} = ctx, bank_id, mental_model_id, opts \\ [])
      when is_binary(bank_id) and is_binary(mental_model_id) do
    backend().delete_mental_model(ctx, bank_id, mental_model_id, opts)
  end

  @spec refresh_mental_model(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def refresh_mental_model(%Context{} = ctx, bank_id, mental_model_id, opts \\ [])
      when is_binary(bank_id) and is_binary(mental_model_id) do
    backend().refresh_mental_model(ctx, bank_id, mental_model_id, opts)
  end

  @spec bank_profile(Context.t(), String.t(), keyword()) :: Backend.result()
  def bank_profile(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().bank_profile(ctx, bank_id, opts)
  end

  @spec list_documents(Context.t(), map(), keyword()) :: Backend.result()
  def list_documents(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().list_documents(ctx, params, opts)
  end

  @spec get_document(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_document(%Context{} = ctx, document_id, opts \\ []) when is_binary(document_id) do
    backend().get_document(ctx, document_id, opts)
  end

  @spec list_document_chunks(Context.t(), String.t(), map(), keyword()) :: Backend.result()
  def list_document_chunks(%Context{} = ctx, document_id, params \\ %{}, opts \\ [])
      when is_binary(document_id) and is_map(params) do
    backend().list_document_chunks(ctx, document_id, params, opts)
  end

  @spec list_audit_logs(Context.t(), map(), keyword()) :: Backend.result()
  def list_audit_logs(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().list_audit_logs(ctx, params, opts)
  end

  @spec audit_log_stats(Context.t(), map(), keyword()) :: Backend.result()
  def audit_log_stats(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().audit_log_stats(ctx, params, opts)
  end

  @spec update_document(Context.t(), String.t(), String.t(), map(), keyword()) :: Backend.result()
  def update_document(%Context{} = ctx, bank_id, document_id, attrs, opts \\ [])
      when is_binary(bank_id) and is_binary(document_id) and is_map(attrs) do
    backend().update_document(ctx, bank_id, document_id, attrs, opts)
  end

  @spec delete_document(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def delete_document(%Context{} = ctx, bank_id, document_id, opts \\ [])
      when is_binary(bank_id) and is_binary(document_id) do
    backend().delete_document(ctx, bank_id, document_id, opts)
  end

  @spec reprocess_document(Context.t(), String.t(), String.t(), keyword()) :: Backend.result()
  def reprocess_document(%Context{} = ctx, bank_id, document_id, opts \\ [])
      when is_binary(bank_id) and is_binary(document_id) do
    backend().reprocess_document(ctx, bank_id, document_id, opts)
  end

  @spec memory_graph(Context.t(), map(), keyword()) :: Backend.result()
  def memory_graph(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().memory_graph(ctx, params, opts)
  end

  @spec get_chunk(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_chunk(%Context{} = ctx, chunk_id, opts \\ []) when is_binary(chunk_id) do
    backend().get_chunk(ctx, chunk_id, opts)
  end

  @spec list_operations(Context.t(), map(), keyword()) :: Backend.result()
  def list_operations(%Context{} = ctx, params \\ %{}, opts \\ []) when is_map(params) do
    backend().list_operations(ctx, params, opts)
  end

  @spec get_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  def get_operation(%Context{} = ctx, operation_id, opts \\ []) when is_binary(operation_id) do
    backend().get_operation(ctx, operation_id, opts)
  end

  @spec cancel_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  def cancel_operation(%Context{} = ctx, operation_id, opts \\ [])
      when is_binary(operation_id) do
    backend().cancel_operation(ctx, operation_id, opts)
  end

  @spec retry_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  def retry_operation(%Context{} = ctx, operation_id, opts \\ [])
      when is_binary(operation_id) do
    backend().retry_operation(ctx, operation_id, opts)
  end

  @spec recover_consolidation(Context.t(), String.t(), keyword()) :: Backend.result()
  def recover_consolidation(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().recover_consolidation(ctx, bank_id, opts)
  end

  @spec clear_observations(Context.t(), String.t(), keyword()) :: Backend.result()
  def clear_observations(%Context{} = ctx, bank_id, opts \\ []) when is_binary(bank_id) do
    backend().clear_observations(ctx, bank_id, opts)
  end

  @spec clear_memory_observations(Context.t(), String.t(), String.t(), keyword()) ::
          Backend.result()
  def clear_memory_observations(%Context{} = ctx, bank_id, memory_id, opts \\ [])
      when is_binary(bank_id) and is_binary(memory_id) do
    backend().clear_memory_observations(ctx, bank_id, memory_id, opts)
  end

  @spec migrate_bank(Context.t(), map(), keyword()) :: Backend.result()
  def migrate_bank(%Context{} = ctx, payload, opts \\ []) when is_map(payload) do
    bank_id = Map.get(payload, "bank_id", ctx.bank)

    if bank_id != ctx.bank do
      {:error, Error.new(:invalid_request, %{message: "bank_id must match context bank"})}
    else
      queue = Foresight.Config.get(:engine, :queue, Foresight.AsyncQueues.Oban)
      repo = Foresight.Config.get(:engine, :repo, Foresight.Repo)
      migrator = Foresight.Config.get(:engine, :bank_migrator, BankMigrator)

      case Map.get(payload, "async", true) do
        false ->
          with {:ok, source_prefix} <- fetch_required(payload, "source_prefix"),
               {:ok, target_prefix} <- fetch_required(payload, "target_prefix") do
            migrator.migrate(
              source_prefix,
              target_prefix,
              bank_id,
              Keyword.put_new(opts, :repo, repo)
            )
          end

        _ ->
          queue.enqueue_migrate_bank(ctx, Map.put(payload, "bank_id", bank_id), opts)
      end
    end
  end

  @spec probe_bank_migration(Context.t(), map(), keyword()) :: Backend.result()
  def probe_bank_migration(%Context{} = ctx, payload, opts \\ []) when is_map(payload) do
    bank_id = Map.get(payload, "bank_id", ctx.bank)

    if bank_id != ctx.bank do
      {:error, Error.new(:invalid_request, %{message: "bank_id must match context bank"})}
    else
      queue = Foresight.Config.get(:engine, :queue, Foresight.AsyncQueues.Oban)
      repo = Foresight.Config.get(:engine, :repo, Foresight.Repo)
      migrator = Foresight.Config.get(:engine, :bank_migrator, BankMigrator)

      case Map.get(payload, "async", false) do
        true ->
          queue.enqueue_probe_bank(ctx, Map.put(payload, "bank_id", bank_id), opts)

        _ ->
          with {:ok, source_prefix} <- fetch_required(payload, "source_prefix"),
               {:ok, target_prefix} <- fetch_required(payload, "target_prefix") do
            migrator.probe(
              source_prefix,
              target_prefix,
              bank_id,
              Keyword.put_new(opts, :repo, repo)
            )
          end
      end
    end
  end

  defp backend do
    Application.get_env(:foresight, :backend, Foresight.Backend.Noop)
  end

  @spec not_implemented(String.t()) :: {:error, Error.t()}
  def not_implemented(operation) do
    {:error, Error.new(:not_implemented, %{operation: operation})}
  end

  defp fetch_required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_request, %{message: "#{key} is required"})}
    end
  end
end
