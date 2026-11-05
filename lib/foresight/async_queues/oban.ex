defmodule Foresight.AsyncQueues.Oban do
  @moduledoc false

  @behaviour Foresight.AsyncQueue

  import Ecto.Query

  alias Foresight.AsyncOptions
  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.Jobs.ConsolidateWorker
  alias Foresight.Jobs.EmbeddingBackfillWorker
  alias Foresight.Jobs.MigrateBankWorker
  alias Foresight.Jobs.ProbeBankWorker
  alias Foresight.Jobs.RefreshMentalModelWorker
  alias Foresight.Jobs.RetainWorker
  alias Foresight.TenantScope
  alias Oban.Job

  @impl true
  def enqueue_retain(%Context{} = ctx, payload, opts) do
    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, tenant_scope} <- tenant_scope_to_map(ctx, opts) do
      job =
        %{
          "context" => context_to_map(ctx),
          "tenant_scope" => tenant_scope,
          "payload" => Map.put(payload, "async", false)
        }
        |> AsyncOptions.put_job_options(opts)
        |> RetainWorker.new()

      case safe_insert(oban_name, job) do
        {:ok, inserted_job} ->
          operation_id = to_string(inserted_job.id)

          {:ok,
           %{
             "success" => true,
             "bank_id" => ctx.bank,
             "items_count" => length(Map.get(payload, "items", [])),
             "async" => true,
             "operation_id" => operation_id,
             "operation_ids" => [operation_id]
           }}

        {:error, reason} ->
          {:error,
           Error.new(:unavailable, %{
             message: "failed to enqueue retain job",
             reason: inspect(reason)
           })}
      end
    end
  end

  @impl true
  def enqueue_consolidate(%Context{} = ctx, payload, opts) do
    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, tenant_scope} <- tenant_scope_to_map(ctx, opts) do
      job =
        %{
          "context" => context_to_map(ctx),
          "tenant_scope" => tenant_scope,
          "payload" => Map.put(payload, "async", false)
        }
        |> AsyncOptions.put_job_options(opts)
        |> ConsolidateWorker.new()

      case safe_insert(oban_name, job) do
        {:ok, inserted_job} ->
          operation_id = to_string(inserted_job.id)

          {:ok,
           %{
             "success" => true,
             "bank_id" => ctx.bank,
             "async" => true,
             "operation_id" => operation_id,
             "operation_ids" => [operation_id]
           }}

        {:error, reason} ->
          {:error,
           Error.new(:unavailable, %{
             message: "failed to enqueue consolidate job",
             reason: inspect(reason)
           })}
      end
    end
  end

  @impl true
  def enqueue_embedding_backfill(%Context{} = ctx, payload, opts) do
    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, tenant_scope} <- tenant_scope_to_map(ctx, opts) do
      job =
        %{
          "context" => context_to_map(ctx),
          "tenant_scope" => tenant_scope,
          "payload" => Map.put(payload, "async", false)
        }
        |> AsyncOptions.put_job_options(opts)
        |> EmbeddingBackfillWorker.new()

      case safe_insert(oban_name, job) do
        {:ok, inserted_job} ->
          operation_id = to_string(inserted_job.id)

          {:ok,
           %{
             "success" => true,
             "bank_id" => ctx.bank,
             "async" => true,
             "operation_id" => operation_id,
             "operation_ids" => [operation_id]
           }}

        {:error, reason} ->
          {:error,
           Error.new(:unavailable, %{
             message: "failed to enqueue embedding_backfill job",
             reason: inspect(reason)
           })}
      end
    end
  end

  @impl true
  def enqueue_refresh_mental_model(%Context{} = ctx, payload, opts) do
    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, tenant_scope} <- tenant_scope_to_map(ctx, opts) do
      job =
        %{
          "context" => context_to_map(ctx),
          "tenant_scope" => tenant_scope,
          "payload" => Map.put(payload, "async", false)
        }
        |> AsyncOptions.put_job_options(opts)
        |> RefreshMentalModelWorker.new()

      case safe_insert(oban_name, job) do
        {:ok, inserted_job} ->
          operation_id = to_string(inserted_job.id)

          {:ok,
           %{
             "success" => true,
             "bank_id" => ctx.bank,
             "async" => true,
             "operation_id" => operation_id,
             "operation_ids" => [operation_id]
           }}

        {:error, reason} ->
          {:error,
           Error.new(:unavailable, %{
             message: "failed to enqueue refresh_mental_model job",
             reason: inspect(reason)
           })}
      end
    end
  end

  @impl true
  def enqueue_migrate_bank(%Context{} = ctx, payload, opts) do
    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, tenant_scope} <- tenant_scope_to_map(ctx, opts) do
      job =
        %{
          "context" => context_to_map(ctx),
          "tenant_scope" => tenant_scope,
          "payload" => Map.put(payload, "async", false)
        }
        |> AsyncOptions.put_job_options(opts)
        |> MigrateBankWorker.new()

      case safe_insert(oban_name, job) do
        {:ok, inserted_job} ->
          operation_id = to_string(inserted_job.id)

          {:ok,
           %{
             "success" => true,
             "bank_id" => ctx.bank,
             "async" => true,
             "operation_id" => operation_id,
             "operation_ids" => [operation_id]
           }}

        {:error, reason} ->
          {:error,
           Error.new(:unavailable, %{
             message: "failed to enqueue migrate_bank job",
             reason: inspect(reason)
           })}
      end
    end
  end

  @impl true
  def enqueue_probe_bank(%Context{} = ctx, payload, opts) do
    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, tenant_scope} <- tenant_scope_to_map(ctx, opts) do
      job =
        %{
          "context" => context_to_map(ctx),
          "tenant_scope" => tenant_scope,
          "payload" => Map.put(payload, "async", false)
        }
        |> AsyncOptions.put_job_options(opts)
        |> ProbeBankWorker.new()

      case safe_insert(oban_name, job) do
        {:ok, inserted_job} ->
          operation_id = to_string(inserted_job.id)

          {:ok,
           %{
             "success" => true,
             "bank_id" => ctx.bank,
             "async" => true,
             "operation_id" => operation_id,
             "operation_ids" => [operation_id]
           }}

        {:error, reason} ->
          {:error,
           Error.new(:unavailable, %{
             message: "failed to enqueue probe_bank job",
             reason: inspect(reason)
           })}
      end
    end
  end

  @impl true
  def list_operations(%Context{} = ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = normalize_limit(params)
    offset = normalize_offset(params)

    operations =
      scoped_operations_query(ctx)
      |> repo.all()
      |> Enum.filter(&job_visible_to_ctx?(&1, ctx))

    {:ok,
     %{
       "bank_id" => ctx.bank,
       "operations" =>
         operations
         |> Enum.drop(offset)
         |> Enum.take(limit)
         |> Enum.map(&operation_summary/1),
       "total" => length(operations),
       "limit" => limit,
       "offset" => offset
     }}
  rescue
    error in DBConnection.ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  @impl true
  def get_operation(%Context{} = ctx, operation_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with {:ok, id} <- parse_operation_id(operation_id),
         %Job{} = job <- fetch_operation_job(repo, ctx, id) do
      {:ok, operation_detail(job)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      nil ->
        {:error, Error.new(:not_found, %{message: "operation not found"})}
    end
  rescue
    error in DBConnection.ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  @impl true
  def cancel_operation(%Context{} = ctx, operation_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, id} <- parse_operation_id(operation_id),
         %Job{} = job <- fetch_operation_job(repo, ctx, id),
         :ok <- ensure_cancelable(job),
         :ok <- safe_call(fn -> Oban.cancel_job(oban_name, job) end) do
      {:ok,
       %{
         "success" => true,
         "message" => "Operation #{operation_id} cancelled",
         "operation_id" => operation_id
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      nil ->
        {:error, Error.new(:not_found, %{message: "operation not found"})}
    end
  rescue
    error in DBConnection.ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  @impl true
  def retry_operation(%Context{} = ctx, operation_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    with {:ok, id} <- parse_operation_id(operation_id),
         %Job{} = job <- fetch_operation_job(repo, ctx, id),
         :ok <- ensure_retryable(job),
         :ok <- safe_call(fn -> Oban.retry_job(oban_name, job) end) do
      {:ok,
       %{
         "success" => true,
         "message" => "Operation #{operation_id} queued for retry",
         "operation_id" => operation_id
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      nil ->
        {:error, Error.new(:not_found, %{message: "operation not found"})}
    end
  rescue
    error in DBConnection.ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  def operation_counts(%Context{} = ctx, opts) do
    repo = Keyword.fetch!(opts, :repo)

    operations =
      scoped_operations_query(ctx)
      |> repo.all()
      |> Enum.filter(&job_visible_to_ctx?(&1, ctx))

    by_status =
      operations
      |> Enum.map(&map_status(&1.state))
      |> Enum.frequencies()

    {:ok,
     %{
       "operations_by_status" => by_status,
       "pending_operations" =>
         Map.get(by_status, "pending", 0) + Map.get(by_status, "processing", 0),
       "failed_operations" => Map.get(by_status, "failed", 0)
     }}
  rescue
    error in DBConnection.ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  defp context_to_map(%Context{} = ctx) do
    %{
      "tenant_id" => ctx.tenant_id,
      "mode" => ctx.mode && Atom.to_string(ctx.mode),
      "bank" => ctx.bank,
      "role_name" => ctx.role_name,
      "prefix" => ctx.prefix,
      "embedding_dim" => ctx.embedding_dim
    }
  end

  defp tenant_scope_to_map(%Context{} = ctx, opts),
    do: TenantScope.authorized_snapshot(ctx, Keyword.get(opts, :tenant_scope))

  defp parse_operation_id(operation_id) do
    case Integer.parse(operation_id) do
      {id, ""} ->
        {:ok, id}

      _ ->
        {:error, Error.new(:invalid_request, %{message: "operation_id must be an integer"})}
    end
  end

  defp job_bank_id(%Job{} = job) do
    job
    |> job_context()
    |> get_map_value("bank")
  end

  defp scoped_operations_query(%Context{} = ctx) do
    base_query =
      from(job in Job,
        where: job.worker in ^operation_workers(),
        where: fragment("?->'context'->>'bank' = ?", job.args, ^ctx.bank),
        order_by: [desc: job.inserted_at, desc: job.id]
      )

    base_query
    |> maybe_scope_operation_context("tenant_id", ctx.tenant_id)
    |> maybe_scope_operation_context("role_name", ctx.role_name)
    |> maybe_scope_operation_context("prefix", ctx.prefix)
  end

  defp maybe_scope_operation_context(query, _field, nil), do: query
  defp maybe_scope_operation_context(query, _field, ""), do: query

  defp maybe_scope_operation_context(query, field, value) do
    from(job in query,
      where: fragment("?->'context'->>? = ?", job.args, ^field, ^value)
    )
  end

  defp ensure_cancelable(%Job{state: state})
       when state in ["available", "scheduled", "retryable", "executing"],
       do: :ok

  defp ensure_cancelable(%Job{}),
    do:
      {:error,
       Error.new(:invalid_request, %{
         message: "operation is not pending and cannot be cancelled"
       })}

  defp ensure_retryable(%Job{state: state}) when state in ["cancelled", "discarded"], do: :ok

  defp ensure_retryable(%Job{}),
    do: {:error, Error.new(:invalid_request, %{message: "operation is not retryable"})}

  defp fetch_operation_job(repo, %Context{} = ctx, id) do
    scoped_operations_query(ctx)
    |> where([job], job.id == ^id)
    |> repo.one()
    |> case do
      %Job{} = job ->
        if job_visible_to_ctx?(job, ctx), do: job, else: nil

      _ ->
        nil
    end
  end

  defp job_visible_to_ctx?(%Job{} = job, %Context{} = ctx) do
    job_bank_id(job) == ctx.bank and
      :ok == TenantScope.validate_context(ctx, job_tenant_scope(job))
  end

  defp job_context(%Job{args: args}) when is_map(args) do
    get_map_value(args, "context")
  end

  defp job_context(_job), do: nil

  defp job_tenant_scope(%Job{args: args}) when is_map(args) do
    get_map_value(args, "tenant_scope")
  end

  defp job_tenant_scope(_job), do: nil

  defp get_map_value(nil, _key), do: nil

  defp get_map_value(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, String.to_atom(key)) -> Map.get(map, String.to_atom(key))
      true -> nil
    end
  end

  defp operation_summary(%Job{} = job) do
    result = Map.get(job.meta || %{}, "operation_result")

    %{
      "id" => Integer.to_string(job.id),
      "task_type" => operation_type(job),
      "items_count" => job_items_count(job),
      "created_at" => datetime_to_iso8601(job.inserted_at),
      "status" => map_status(job.state),
      "error_message" => latest_error(job),
      "retry_count" => length(job.errors || []),
      "next_retry_at" => next_retry_at(job)
    }
    |> Map.merge(operation_result_digest(result))
  end

  defp operation_detail(%Job{} = job) do
    result = Map.get(job.meta || %{}, "operation_result")

    %{
      "operation_id" => Integer.to_string(job.id),
      "status" => map_status(job.state),
      "operation_type" => operation_type(job),
      "created_at" => datetime_to_iso8601(job.inserted_at),
      "updated_at" => operation_updated_at(job),
      "completed_at" => datetime_to_iso8601(job.completed_at),
      "error_message" => latest_error(job),
      "retry_count" => length(job.errors || []),
      "next_retry_at" => next_retry_at(job),
      "result" => result,
      "task_payload" => sanitize_task_payload(Map.get(job.args, "payload"))
    }
    |> Map.merge(operation_result_digest(result))
  end

  defp job_items_count(%Job{} = job) do
    job.args
    |> Map.get("payload", %{})
    |> Map.get("items", [])
    |> length()
  end

  defp operation_workers do
    [
      RetainWorker,
      ConsolidateWorker,
      EmbeddingBackfillWorker,
      RefreshMentalModelWorker,
      MigrateBankWorker,
      ProbeBankWorker
    ]
    |> Enum.flat_map(&worker_names/1)
    |> Enum.uniq()
  end

  defp operation_type(%Job{worker: worker}) do
    cond do
      worker_matches?(worker, ConsolidateWorker) -> "consolidate"
      worker_matches?(worker, EmbeddingBackfillWorker) -> "embedding_backfill"
      worker_matches?(worker, RefreshMentalModelWorker) -> "refresh_mental_model"
      worker_matches?(worker, MigrateBankWorker) -> "migrate_bank"
      worker_matches?(worker, ProbeBankWorker) -> "probe_bank_migration"
      true -> "retain"
    end
  end

  defp map_status("completed"), do: "completed"
  defp map_status("cancelled"), do: "cancelled"
  defp map_status("discarded"), do: "failed"
  defp map_status("executing"), do: "processing"
  defp map_status(_state), do: "pending"

  defp latest_error(%Job{errors: []}), do: nil
  defp latest_error(%Job{errors: errors}), do: errors |> List.last() |> Map.get("error")

  defp next_retry_at(%Job{state: "retryable"} = job), do: datetime_to_iso8601(job.scheduled_at)
  defp next_retry_at(_job), do: nil

  defp operation_updated_at(%Job{} = job) do
    [
      job.completed_at,
      job.cancelled_at,
      job.discarded_at,
      job.attempted_at,
      job.scheduled_at,
      job.inserted_at
    ]
    |> Enum.find(& &1)
    |> datetime_to_iso8601()
  end

  defp datetime_to_iso8601(nil), do: nil
  defp datetime_to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp normalize_limit(params), do: Map.get(params, "limit", 100)
  defp normalize_offset(params), do: Map.get(params, "offset", 0)

  defp sanitize_task_payload(%{} = payload), do: Map.drop(payload, ["__operation__"])
  defp sanitize_task_payload(payload), do: payload

  defp operation_result_digest(%{} = result) do
    digest = %{
      "result_diagnostic_type" => get_map_value(result, "diagnostic_type"),
      "result_stage" => infer_result_stage(result),
      "result_failure_kind" => get_map_value(result, "failure_kind"),
      "result_excluded_surfaces" => infer_excluded_surfaces(result),
      "result_source_compatible" => infer_source_compatible(result),
      "result_target_provisioned" => infer_target_provisioned(result),
      "result_target_migrated_version_count" => infer_target_migrated_version_count(result),
      "result_items_count" => infer_result_items_count(result),
      "result_operation" => infer_result_operation(result),
      "result_observations_created" => infer_observations_created(result),
      "result_scopes_consolidated" => infer_scopes_consolidated(result),
      "result_copy_dependency" => infer_copy_dependency(result),
      "result_copy_total_rows" => infer_copy_total_rows(result),
      "result_copy_blocked_rows" => infer_copy_blocked_rows(result),
      "result_clean" => infer_result_clean(result),
      "result_has_probe_drift" => infer_probe_drift(result),
      "result_has_copy_incompleteness" => infer_copy_incompleteness(result),
      "result_copy_counts" => infer_copy_counts(result),
      "result_probe_counts" => infer_probe_counts(result),
      "result_probe_mismatch_counts" => infer_probe_mismatch_counts(result)
    }

    Enum.reject(digest, fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp operation_result_digest(_result), do: %{}

  defp infer_result_stage(result) do
    get_map_value(result, "stage") ||
      cond do
        is_map(get_map_value(result, "parity_probe")) -> "probe"
        is_map(get_map_value(result, "copy_result")) -> "copy"
        true -> nil
      end
  end

  defp infer_result_clean(result) do
    result
    |> get_map_value("parity_probe")
    |> get_map_value("clean?")
  end

  defp infer_excluded_surfaces(result) do
    case result |> get_map_value("migration_policy") |> get_map_value("excluded_surfaces") do
      surfaces when is_list(surfaces) -> surfaces
      _ -> nil
    end
  end

  defp infer_source_compatible(result) do
    result
    |> get_map_value("source_audit")
    |> get_map_value("compatible?")
  end

  defp infer_target_provisioned(result) do
    if is_map(get_map_value(result, "target_provisioned")), do: true, else: nil
  end

  defp infer_target_migrated_version_count(result) do
    case result |> get_map_value("target_provisioned") |> get_map_value("migrated_versions") do
      versions when is_list(versions) -> length(versions)
      _ -> nil
    end
  end

  defp infer_result_items_count(result) do
    case get_map_value(result, "items_count") do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp infer_result_operation(result), do: get_map_value(result, "operation")

  defp infer_observations_created(result) do
    case get_map_value(result, "observations_created") do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp infer_scopes_consolidated(result) do
    case get_map_value(result, "scopes_consolidated") do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp infer_probe_drift(result) do
    cond do
      get_map_value(result, "failure_kind") == "parity_probe_failed" -> true
      infer_result_clean(result) == true -> false
      true -> nil
    end
  end

  defp infer_copy_incompleteness(result) do
    cond do
      get_map_value(result, "failure_kind") == "incomplete_dependent_rows" ->
        true

      is_map(get_map_value(result, "copy_result")) or
          map_size(infer_copy_counts(result) || %{}) > 0 ->
        false

      true ->
        nil
    end
  end

  defp infer_copy_dependency(result) do
    cond do
      get_map_value(result, "failure_kind") == "incomplete_dependent_rows" ->
        result
        |> get_map_value("detail")
        |> get_map_value("dependency")

      true ->
        nil
    end
  end

  defp infer_copy_total_rows(result) do
    cond do
      get_map_value(result, "failure_kind") == "incomplete_dependent_rows" ->
        result
        |> get_map_value("detail")
        |> get_map_value("total_rows")

      true ->
        nil
    end
  end

  defp infer_copy_blocked_rows(result) do
    cond do
      get_map_value(result, "failure_kind") == "incomplete_dependent_rows" ->
        total_rows = infer_copy_total_rows(result)

        eligible_rows =
          result
          |> get_map_value("detail")
          |> get_map_value("eligible_rows")

        if is_integer(total_rows) and is_integer(eligible_rows) do
          max(total_rows - eligible_rows, 0)
        else
          nil
        end

      true ->
        nil
    end
  end

  defp infer_copy_counts(result) do
    copy =
      get_map_value(result, "copy_result")
      |> then(fn
        %{} = copy -> copy
        _ -> result
      end)

    copy_keys = [
      "copied_banks",
      "copied_file_storage",
      "copied_documents",
      "copied_memory_units",
      "copied_entities",
      "copied_memory_unit_entities",
      "copied_entity_links"
    ]

    extract_count_subset(copy, copy_keys)
  end

  defp infer_probe_counts(result) do
    probe =
      get_map_value(result, "parity_probe")
      |> then(fn
        %{} = probe -> probe
        _ -> result
      end)

    probe_keys = [
      "source_file_storage_count",
      "target_file_storage_count",
      "source_document_count",
      "target_document_count",
      "source_memory_unit_count",
      "target_memory_unit_count",
      "source_entity_count",
      "target_entity_count",
      "source_memory_unit_entity_count",
      "target_memory_unit_entity_count",
      "source_entity_link_count",
      "target_entity_link_count"
    ]

    extract_count_subset(probe, probe_keys)
  end

  defp infer_probe_mismatch_counts(result) do
    probe = extract_probe_shape(result)

    mismatch_keys = [
      "missing_file_storage_keys",
      "extra_file_storage_keys",
      "mismatched_file_storage_keys",
      "missing_document_ids",
      "extra_document_ids",
      "mismatched_document_ids",
      "missing_in_target",
      "extra_in_target",
      "mismatched_memory_unit_ids",
      "missing_entity_ids",
      "extra_entity_ids",
      "mismatched_entity_ids",
      "missing_memory_unit_entities",
      "extra_memory_unit_entities",
      "missing_entity_links",
      "extra_entity_links"
    ]

    mismatch_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case get_map_value(probe, key) do
        values when is_list(values) -> Map.put(acc, key, length(values))
        _ -> acc
      end
    end)
    |> case do
      counts when map_size(counts) == 0 -> nil
      counts -> counts
    end
  end

  defp extract_probe_shape(result) when is_map(result) do
    cond do
      is_map(get_map_value(result, "detail")) ->
        detail = get_map_value(result, "detail")
        get_map_value(detail, "parity_probe") || detail

      is_map(get_map_value(result, "parity_probe")) ->
        get_map_value(result, "parity_probe")

      true ->
        result
    end
  end

  defp extract_probe_shape(_result), do: %{}

  defp extract_count_subset(%{} = map, keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case get_map_value(map, key) do
        value when is_integer(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
    |> case do
      counts when map_size(counts) == 0 -> nil
      counts -> counts
    end
  end

  defp extract_count_subset(_map, _keys), do: nil

  defp worker_matches?(worker, module) when is_binary(worker) do
    worker in worker_names(module)
  end

  defp worker_names(module) when is_atom(module) do
    [inspect(module), module |> Atom.to_string() |> String.trim_leading("Elixir.")]
  end

  # Oban.insert/2 RAISES when the named Oban instance is not running — "unknown registry:
  # Oban.Registry" — rather than returning the {:error, reason} its callers already handle.
  # An operator who enables a surface without Oban therefore got a raw ArgumentError out of
  # retain: a 500 on the REST face, and on MCP only the rescue kept it from taking
  # the session process down. Turning it into the error tuple the call sites already expect
  # makes "you asked to queue this and there is no queue" a legible answer.
  defp safe_insert(oban_name, job), do: safe_call(fn -> Oban.insert(oban_name, job) end)

  defp safe_call(fun) do
    fun.()
  rescue
    error in [ArgumentError, RuntimeError] ->
      {:error, {:queue_unavailable, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:queue_unavailable, inspect(reason)}}
  end
end
