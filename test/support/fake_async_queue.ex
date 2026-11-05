defmodule Foresight.TestSupport.FakeAsyncQueue do
  @moduledoc false

  use Agent

  @behaviour Foresight.AsyncQueue

  alias Foresight.Migration.BankMigrator
  alias Foresight.TenantScope

  def start_link(_opts) do
    Agent.start_link(fn -> %{jobs: [], seq: 0} end, name: __MODULE__)
  end

  def reset! do
    Agent.update(__MODULE__, fn _ -> %{jobs: [], seq: 0} end)
  end

  def drain! do
    {jobs, storage, opts} =
      Agent.get_and_update(__MODULE__, fn state ->
        jobs =
          state.jobs
          |> Enum.reverse()
          |> Enum.filter(&(&1.status == "pending"))

        {jobs, state}
      end)
      |> then(fn jobs ->
        opts = [
          storage: Foresight.Config.get(:engine, :storage, Foresight.Storage.Ecto),
          repo: Foresight.Config.get(:engine, :repo, Foresight.Repo),
          embedder: Foresight.Config.get(:engine, :embedder, Foresight.Embedders.Noop),
          reranker: Foresight.Config.get(:engine, :reranker, Foresight.Rerankers.Passthrough),
          llm: Foresight.Config.get(:engine, :llm, Foresight.LLMs.Noop),
          queue: __MODULE__,
          oban_name: Foresight.Config.get(:engine, :oban_name, Foresight.Oban)
        ]

        storage = Keyword.fetch!(opts, :storage)

        {jobs, storage, opts}
      end)

    Enum.each(jobs, fn %{id: job_id, ctx: ctx, payload: payload} ->
      completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        case Map.get(payload, "__operation__", "retain") do
          "consolidate" -> storage.consolidate(ctx, Map.put(payload, "async", false), opts)
          "embedding_backfill" -> drain_embedding_backfill(ctx, payload, opts)
          "refresh_mental_model" -> drain_refresh_mental_model(ctx, payload, opts)
          "migrate_bank" -> drain_migrate_bank(ctx, payload, opts)
          "probe_bank_migration" -> drain_probe_bank(ctx, payload, opts)
          _ -> storage.retain(ctx, Map.put(payload, "async", false), opts)
        end

      Agent.update(__MODULE__, fn state ->
        jobs =
          Enum.map(state.jobs, fn job ->
            if job.id == job_id do
              case result do
                {:ok, _} ->
                  %{
                    job
                    | status: "completed",
                      completed_at: completed_at,
                      updated_at: completed_at,
                      result: operation_result(job.operation_type, result)
                  }

                {:error, error} ->
                  %{
                    job
                    | status: "failed",
                      updated_at: completed_at,
                      result: operation_failure_result(job.operation_type, error),
                      error_message: operation_error_message(error),
                      retry_count: job.retry_count + 1
                  }
              end
            else
              job
            end
          end)

        %{state | jobs: jobs}
      end)
    end)
  end

  @impl true
  def enqueue_retain(ctx, payload, opts) do
    enqueue_operation(ctx, payload, "retain", opts)
  end

  @impl true
  def enqueue_consolidate(ctx, payload, opts) do
    enqueue_operation(ctx, payload, "consolidate", opts)
  end

  @impl true
  def enqueue_embedding_backfill(ctx, payload, opts) do
    enqueue_operation(ctx, payload, "embedding_backfill", opts)
  end

  @impl true
  def enqueue_refresh_mental_model(ctx, payload, opts) do
    enqueue_operation(ctx, payload, "refresh_mental_model", opts)
  end

  @impl true
  def enqueue_migrate_bank(ctx, payload, opts) do
    enqueue_operation(ctx, payload, "migrate_bank", opts)
  end

  @impl true
  def enqueue_probe_bank(ctx, payload, opts) do
    enqueue_operation(ctx, payload, "probe_bank_migration", opts)
  end

  defp enqueue_operation(ctx, payload, operation_type, opts) do
    with {:ok, tenant_scope} <-
           TenantScope.authorized_snapshot(ctx, Keyword.get(opts, :tenant_scope)) do
      Agent.get_and_update(__MODULE__, fn state ->
        job_id = state.seq + 1
        created_at = DateTime.utc_now() |> DateTime.truncate(:second)

        job = %{
          id: job_id,
          ctx: ctx,
          tenant_scope: tenant_scope,
          payload: payload |> Map.put("async", false) |> Map.put("__operation__", operation_type),
          operation_type: operation_type,
          status: "pending",
          created_at: created_at,
          updated_at: created_at,
          completed_at: nil,
          result: nil,
          error_message: nil,
          retry_count: 0
        }

        response =
          %{
            "success" => true,
            "bank_id" => ctx.bank,
            "async" => true,
            "operation_id" => Integer.to_string(job_id),
            "operation_ids" => [Integer.to_string(job_id)]
          }
          |> maybe_put_items_count(operation_type, payload)

        {response, %{state | seq: job_id, jobs: [job | state.jobs]}}
      end)
      |> then(&{:ok, &1})
    end
  end

  @impl true
  def list_operations(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)

    operations =
      Agent.get(__MODULE__, fn state ->
        state.jobs
        |> Enum.filter(&job_visible_to_ctx?(&1, ctx))
        |> Enum.sort_by(
          fn job -> {DateTime.to_unix(job.created_at, :microsecond), job.id} end,
          :desc
        )
      end)

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
  end

  @impl true
  def get_operation(ctx, operation_id, _opts) do
    with {id, ""} <- Integer.parse(operation_id),
         job when not is_nil(job) <-
           Agent.get(__MODULE__, fn state ->
             Enum.find(state.jobs, &(&1.id == id and job_visible_to_ctx?(&1, ctx)))
           end) do
      {:ok, operation_detail(job)}
    else
      :error ->
        {:error,
         Foresight.Error.new(:invalid_request, %{message: "operation_id must be an integer"})}

      nil ->
        {:error, Foresight.Error.new(:not_found, %{message: "operation not found"})}

      {_id, _rest} ->
        {:error,
         Foresight.Error.new(:invalid_request, %{message: "operation_id must be an integer"})}
    end
  end

  @impl true
  def cancel_operation(ctx, operation_id, _opts) do
    with {id, ""} <- Integer.parse(operation_id),
         {:ok, _job} <- update_visible_job(ctx, id, &cancel_job/1) do
      {:ok,
       %{
         "success" => true,
         "message" => "Operation #{operation_id} cancelled",
         "operation_id" => operation_id
       }}
    else
      :error ->
        {:error,
         Foresight.Error.new(:invalid_request, %{message: "operation_id must be an integer"})}

      {:error, reason} ->
        {:error, reason}

      {_id, _rest} ->
        {:error,
         Foresight.Error.new(:invalid_request, %{message: "operation_id must be an integer"})}
    end
  end

  @impl true
  def retry_operation(ctx, operation_id, _opts) do
    with {id, ""} <- Integer.parse(operation_id),
         {:ok, _job} <- update_visible_job(ctx, id, &retry_job/1) do
      {:ok,
       %{
         "success" => true,
         "message" => "Operation #{operation_id} queued for retry",
         "operation_id" => operation_id
       }}
    else
      :error ->
        {:error,
         Foresight.Error.new(:invalid_request, %{message: "operation_id must be an integer"})}

      {:error, reason} ->
        {:error, reason}

      {_id, _rest} ->
        {:error,
         Foresight.Error.new(:invalid_request, %{message: "operation_id must be an integer"})}
    end
  end

  def operation_counts(ctx, _opts) do
    by_status =
      Agent.get(__MODULE__, fn state ->
        state.jobs
        |> Enum.filter(&job_visible_to_ctx?(&1, ctx))
        |> Enum.map(& &1.status)
        |> Enum.frequencies()
      end)

    {:ok,
     %{
       "operations_by_status" => by_status,
       "pending_operations" =>
         Map.get(by_status, "pending", 0) + Map.get(by_status, "processing", 0),
       "failed_operations" => Map.get(by_status, "failed", 0)
     }}
  end

  defp operation_summary(job) do
    result = job.result

    %{
      "id" => Integer.to_string(job.id),
      "task_type" => job.operation_type,
      "items_count" => length(Map.get(job.payload, "items", [])),
      "created_at" => DateTime.to_iso8601(job.created_at),
      "status" => job.status,
      "error_message" => job.error_message,
      "retry_count" => job.retry_count,
      "next_retry_at" => nil
    }
    |> Map.merge(operation_result_digest(result))
  end

  defp operation_detail(job) do
    result = job.result

    %{
      "operation_id" => Integer.to_string(job.id),
      "status" => job.status,
      "operation_type" => job.operation_type,
      "created_at" => DateTime.to_iso8601(job.created_at),
      "updated_at" => DateTime.to_iso8601(job.updated_at),
      "completed_at" => job.completed_at && DateTime.to_iso8601(job.completed_at),
      "error_message" => job.error_message,
      "retry_count" => job.retry_count,
      "next_retry_at" => nil,
      "result" => result,
      "task_payload" => sanitize_task_payload(job.payload)
    }
    |> Map.merge(operation_result_digest(result))
  end

  defp update_visible_job(ctx, id, updater) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Enum.find(state.jobs, &(&1.id == id and job_visible_to_ctx?(&1, ctx))) do
        nil ->
          {{:error, Foresight.Error.new(:not_found, %{message: "operation not found"})}, state}

        job ->
          case updater.(job) do
            {:ok, updated_job} ->
              jobs =
                Enum.map(state.jobs, fn current ->
                  if current.id == id, do: updated_job, else: current
                end)

              {{:ok, updated_job}, %{state | jobs: jobs}}

            {:error, reason} ->
              {{:error, reason}, state}
          end
      end
    end)
  end

  defp cancel_job(%{status: status} = job) when status in ["pending", "processing"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, %{job | status: "cancelled", updated_at: now, completed_at: now, error_message: nil}}
  end

  defp cancel_job(_job) do
    {:error,
     Foresight.Error.new(:invalid_request, %{
       message: "operation is not pending and cannot be cancelled"
     })}
  end

  defp retry_job(%{status: status} = job) when status in ["failed", "cancelled"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok,
     %{
       job
       | status: "pending",
         updated_at: now,
         completed_at: nil,
         result: nil,
         error_message: nil
     }}
  end

  defp retry_job(_job) do
    {:error, Foresight.Error.new(:invalid_request, %{message: "operation is not retryable"})}
  end

  defp job_visible_to_ctx?(job, ctx) do
    job.ctx.bank == ctx.bank and :ok == TenantScope.validate_context(ctx, job.tenant_scope)
  end

  defp maybe_put_items_count(response, "retain", payload) do
    Map.put(response, "items_count", length(Map.get(payload, "items", [])))
  end

  defp maybe_put_items_count(response, _operation_type, _payload), do: response

  defp drain_migrate_bank(ctx, payload, opts) do
    with source_prefix when is_binary(source_prefix) and source_prefix != "" <-
           Map.get(payload, "source_prefix"),
         target_prefix when is_binary(target_prefix) and target_prefix != "" <-
           Map.get(payload, "target_prefix") do
      bank_id = Map.get(payload, "bank_id", ctx.bank)

      migrator = Foresight.Config.get(:engine, :bank_migrator, BankMigrator)

      migrator.migrate(source_prefix, target_prefix, bank_id, repo: Keyword.fetch!(opts, :repo))
    else
      _ ->
        {:error,
         Foresight.Error.new(:invalid_request, %{
           message: "source_prefix and target_prefix are required"
         })}
    end
  end

  defp drain_probe_bank(ctx, payload, opts) do
    with source_prefix when is_binary(source_prefix) and source_prefix != "" <-
           Map.get(payload, "source_prefix"),
         target_prefix when is_binary(target_prefix) and target_prefix != "" <-
           Map.get(payload, "target_prefix") do
      bank_id = Map.get(payload, "bank_id", ctx.bank)

      migrator = Foresight.Config.get(:engine, :bank_migrator, BankMigrator)

      migrator.probe(source_prefix, target_prefix, bank_id, repo: Keyword.fetch!(opts, :repo))
    else
      _ ->
        {:error,
         Foresight.Error.new(:invalid_request, %{
           message: "source_prefix and target_prefix are required"
         })}
    end
  end

  defp drain_embedding_backfill(ctx, payload, opts) do
    storage = Keyword.fetch!(opts, :storage)

    if function_exported?(storage, :backfill_embeddings, 3) do
      storage.backfill_embeddings(ctx, Map.put(payload, "async", false), opts)
    else
      {:error,
       Foresight.Error.new(:not_implemented, %{
         message: "#{inspect(storage)} does not implement backfill_embeddings/3"
       })}
    end
  end

  defp drain_refresh_mental_model(ctx, payload, opts) do
    storage = Keyword.fetch!(opts, :storage)

    if function_exported?(storage, :refresh_mental_model_operation, 3) do
      storage.refresh_mental_model_operation(ctx, Map.put(payload, "async", false), opts)
    else
      {:error,
       Foresight.Error.new(:not_implemented, %{
         message: "#{inspect(storage)} does not implement refresh_mental_model_operation/3"
       })}
    end
  end

  defp operation_error_message(%Foresight.Error{detail: %{message: message}})
       when is_binary(message) and message != "",
       do: message

  defp operation_error_message(error), do: inspect(error)

  defp operation_result("retain", {:ok, result}), do: normalize_result_payload(result)
  defp operation_result("retain", result), do: normalize_result_payload(result)
  defp operation_result("consolidate", {:ok, result}), do: normalize_result_payload(result)
  defp operation_result("consolidate", result), do: normalize_result_payload(result)
  defp operation_result("embedding_backfill", {:ok, result}), do: normalize_result_payload(result)
  defp operation_result("embedding_backfill", result), do: normalize_result_payload(result)

  defp operation_result("refresh_mental_model", {:ok, result}),
    do: normalize_result_payload(result)

  defp operation_result("refresh_mental_model", result), do: normalize_result_payload(result)
  defp operation_result("migrate_bank", {:ok, result}), do: normalize_result_payload(result)
  defp operation_result("migrate_bank", result), do: normalize_result_payload(result)

  defp operation_result("probe_bank_migration", {:ok, result}),
    do: normalize_result_payload(result)

  defp operation_result("probe_bank_migration", result), do: normalize_result_payload(result)
  defp operation_result(_operation_type, _result), do: nil

  defp operation_failure_result("retain", %Foresight.Error{reason: reason, detail: detail}) do
    %{
      "diagnostic_type" => "foresight_error",
      "reason" => to_string(reason),
      "detail" => normalize_result_payload(detail)
    }
  end

  defp operation_failure_result("retain", reason) do
    %{
      "diagnostic_type" => "opaque_error",
      "detail" => inspect(reason)
    }
  end

  defp operation_failure_result("consolidate", %Foresight.Error{reason: reason, detail: detail}) do
    %{
      "diagnostic_type" => "foresight_error",
      "reason" => to_string(reason),
      "detail" => normalize_result_payload(detail)
    }
  end

  defp operation_failure_result("embedding_backfill", %Foresight.Error{
         reason: reason,
         detail: detail
       }) do
    %{"reason" => to_string(reason), "detail" => normalize_result_payload(detail)}
  end

  defp operation_failure_result("refresh_mental_model", %Foresight.Error{
         reason: reason,
         detail: detail
       }) do
    %{
      "diagnostic_type" => "foresight_error",
      "reason" => to_string(reason),
      "detail" => normalize_result_payload(detail)
    }
  end

  defp operation_failure_result("consolidate", reason) do
    %{
      "diagnostic_type" => "opaque_error",
      "detail" => inspect(reason)
    }
  end

  defp operation_failure_result("refresh_mental_model", reason) do
    %{
      "diagnostic_type" => "opaque_error",
      "detail" => inspect(reason)
    }
  end

  defp operation_failure_result("migrate_bank", {:migration_diagnostics, detail})
       when is_map(detail) do
    detail
    |> normalize_result_payload()
    |> Map.put("diagnostic_type", "migration_diagnostics")
  end

  defp operation_failure_result("migrate_bank", %Foresight.Error{reason: reason, detail: detail}) do
    %{
      "diagnostic_type" => "foresight_error",
      "reason" => to_string(reason),
      "detail" => normalize_result_payload(detail)
    }
  end

  defp operation_failure_result("migrate_bank", reason) do
    %{
      "diagnostic_type" => "opaque_error",
      "detail" => inspect(reason)
    }
  end

  defp operation_failure_result("probe_bank_migration", {:migration_diagnostics, detail})
       when is_map(detail) do
    detail
    |> normalize_result_payload()
    |> Map.put("diagnostic_type", "migration_diagnostics")
  end

  defp operation_failure_result("probe_bank_migration", %Foresight.Error{
         reason: reason,
         detail: detail
       }) do
    %{
      "diagnostic_type" => "foresight_error",
      "reason" => to_string(reason),
      "detail" => normalize_result_payload(detail)
    }
  end

  defp operation_failure_result("probe_bank_migration", reason) do
    %{
      "diagnostic_type" => "opaque_error",
      "detail" => inspect(reason)
    }
  end

  defp operation_failure_result(_operation_type, _reason), do: nil

  defp normalize_result_payload(%{} = payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), normalize_result_payload(value)} end)
  end

  defp normalize_result_payload(list) when is_list(list),
    do: Enum.map(list, &normalize_result_payload/1)

  defp normalize_result_payload(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize_result_payload(value), do: value

  defp sanitize_task_payload(%{} = payload), do: Map.drop(payload, ["__operation__"])
  defp sanitize_task_payload(payload), do: payload

  defp operation_result_digest(%{} = result) do
    digest = %{
      "result_diagnostic_type" => Map.get(result, "diagnostic_type"),
      "result_stage" => infer_result_stage(result),
      "result_failure_kind" => Map.get(result, "failure_kind"),
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
    Map.get(result, "stage") ||
      cond do
        is_map(Map.get(result, "parity_probe")) -> "probe"
        is_map(Map.get(result, "copy_result")) -> "copy"
        true -> nil
      end
  end

  defp infer_result_clean(result) do
    result
    |> Map.get("parity_probe")
    |> then(fn
      %{} = probe -> Map.get(probe, "clean?")
      _ -> nil
    end)
  end

  defp infer_excluded_surfaces(result) do
    result
    |> Map.get("migration_policy")
    |> then(fn
      %{"excluded_surfaces" => surfaces} when is_list(surfaces) -> surfaces
      _ -> nil
    end)
  end

  defp infer_source_compatible(result) do
    result
    |> Map.get("source_audit")
    |> then(fn
      %{} = source_audit -> Map.get(source_audit, "compatible?")
      _ -> nil
    end)
  end

  defp infer_target_provisioned(result) do
    if is_map(Map.get(result, "target_provisioned")), do: true, else: nil
  end

  defp infer_target_migrated_version_count(result) do
    result
    |> Map.get("target_provisioned")
    |> then(fn
      %{"migrated_versions" => versions} when is_list(versions) -> length(versions)
      _ -> nil
    end)
  end

  defp infer_probe_drift(result) do
    cond do
      Map.get(result, "failure_kind") == "parity_probe_failed" -> true
      infer_result_clean(result) == true -> false
      true -> nil
    end
  end

  defp infer_result_items_count(result) do
    case Map.get(result, "items_count") do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp infer_result_operation(result), do: Map.get(result, "operation")

  defp infer_observations_created(result) do
    case Map.get(result, "observations_created") do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp infer_scopes_consolidated(result) do
    case Map.get(result, "scopes_consolidated") do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp infer_copy_incompleteness(result) do
    cond do
      Map.get(result, "failure_kind") == "incomplete_dependent_rows" ->
        true

      is_map(Map.get(result, "copy_result")) or map_size(infer_copy_counts(result) || %{}) > 0 ->
        false

      true ->
        nil
    end
  end

  defp infer_copy_dependency(result) do
    cond do
      Map.get(result, "failure_kind") == "incomplete_dependent_rows" ->
        result
        |> Map.get("detail")
        |> then(fn
          %{} = detail -> Map.get(detail, "dependency")
          _ -> nil
        end)

      true ->
        nil
    end
  end

  defp infer_copy_total_rows(result) do
    cond do
      Map.get(result, "failure_kind") == "incomplete_dependent_rows" ->
        result
        |> Map.get("detail")
        |> then(fn
          %{} = detail -> Map.get(detail, "total_rows")
          _ -> nil
        end)

      true ->
        nil
    end
  end

  defp infer_copy_blocked_rows(result) do
    cond do
      Map.get(result, "failure_kind") == "incomplete_dependent_rows" ->
        total_rows = infer_copy_total_rows(result)

        eligible_rows =
          result
          |> Map.get("detail")
          |> then(fn
            %{} = detail -> Map.get(detail, "eligible_rows")
            _ -> nil
          end)

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
      result
      |> Map.get("copy_result")
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
      result
      |> Map.get("parity_probe")
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
      case Map.get(probe, key) do
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
      is_map(Map.get(result, "detail")) ->
        detail = Map.get(result, "detail")
        Map.get(detail, "parity_probe") || detail

      is_map(Map.get(result, "parity_probe")) ->
        Map.get(result, "parity_probe")

      true ->
        result
    end
  end

  defp extract_probe_shape(_result), do: %{}

  defp extract_count_subset(%{} = map, keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(map, key) do
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
end
