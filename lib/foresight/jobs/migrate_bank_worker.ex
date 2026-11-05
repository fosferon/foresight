defmodule Foresight.Jobs.MigrateBankWorker do
  @moduledoc false

  import Ecto.Query

  use Oban.Worker, queue: :foresight_migrate_bank, max_attempts: 5

  alias Foresight.AsyncOptions
  alias Foresight.Context
  alias Foresight.Migration.BankMigrator
  alias Foresight.TenantScope
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{"context" => context_map, "payload" => payload} = args
      }) do
    ctx = context_from_map(context_map)
    repo = Foresight.Config.get(:engine, :repo, Foresight.Repo)
    migrator = Foresight.Config.get(:engine, :bank_migrator, BankMigrator)

    with :ok <- TenantScope.validate_context(ctx, Map.get(args, "tenant_scope")),
         {:ok, source_prefix} <- fetch_required(payload, "source_prefix"),
         {:ok, target_prefix} <- fetch_required(payload, "target_prefix"),
         bank_id <- Map.get(payload, "bank_id", ctx.bank),
         {:ok, result} <-
           migrator.migrate(
             source_prefix,
             target_prefix,
             bank_id,
             AsyncOptions.restore(args, repo: repo)
           ) do
      # Best-effort meta write: a 0-row update must not trigger an Oban retry of an
      # already-committed migration. See RetainWorker for the rationale.
      _ = persist_result(job_id, result, repo)
      :ok
    else
      {:error, reason} ->
        _ = persist_failure_result(job_id, reason, repo)
        {:error, reason}
    end
  end

  defp fetch_required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Foresight.Error.new(:invalid_request, %{message: "#{key} is required"})}
    end
  end

  defp context_from_map(map) do
    %Context{
      tenant_id: map["tenant_id"],
      mode: parse_mode(map["mode"]),
      bank: map["bank"],
      role_name: map["role_name"],
      prefix: map["prefix"],
      embedding_dim: map["embedding_dim"]
    }
  end

  defp parse_mode(nil), do: nil
  defp parse_mode("mode_a"), do: :mode_a
  defp parse_mode("mode_b"), do: :mode_b
  defp parse_mode("mode_c"), do: :mode_c
  defp parse_mode(mode) when is_atom(mode), do: mode
  # Unknown mode string (e.g. a stale atom from an old release) must not raise on
  # every retry and poison the queue; resolve it to nil and let with_tenant_role/3
  # fail closed.
  defp parse_mode(_mode), do: nil

  defp persist_result(nil, _result, _repo), do: {1, nil}

  defp persist_result(job_id, result, repo) do
    normalized_result = normalize_result_payload(result)

    repo.update_all(
      from(job in Job, where: job.id == ^job_id),
      set: [meta: %{"operation_result" => normalized_result}]
    )
  end

  defp persist_failure_result(nil, _reason, _repo), do: {1, nil}

  defp persist_failure_result(job_id, reason, repo) do
    normalized_result = normalize_failure_payload(reason)

    repo.update_all(
      from(job in Job, where: job.id == ^job_id),
      set: [meta: %{"operation_result" => normalized_result}]
    )
  end

  defp normalize_result_payload(%{} = payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), normalize_result_payload(value)} end)
  end

  defp normalize_result_payload(list) when is_list(list),
    do: Enum.map(list, &normalize_result_payload/1)

  defp normalize_result_payload(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize_result_payload(value), do: value

  defp normalize_failure_payload({:migration_diagnostics, detail}) when is_map(detail) do
    detail
    |> normalize_result_payload()
    |> Map.put("diagnostic_type", "migration_diagnostics")
  end

  defp normalize_failure_payload(%Foresight.Error{reason: reason, detail: detail}) do
    %{
      "diagnostic_type" => "foresight_error",
      "reason" => to_string(reason),
      "detail" => normalize_result_payload(detail)
    }
  end

  defp normalize_failure_payload(reason) do
    %{
      "diagnostic_type" => "opaque_error",
      "detail" => inspect(reason)
    }
  end
end
