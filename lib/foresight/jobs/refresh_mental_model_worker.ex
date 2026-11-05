defmodule Foresight.Jobs.RefreshMentalModelWorker do
  @moduledoc false

  import Ecto.Query

  use Oban.Worker, queue: :foresight_refresh_mental_model, max_attempts: 5

  alias Foresight.AsyncOptions
  alias Foresight.Context
  alias Foresight.TenantScope
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Job{id: job_id, args: %{"context" => context_map, "payload" => payload} = args}) do
    ctx = context_from_map(context_map)
    storage = Foresight.Config.get(:engine, :storage, Foresight.Storage.Ecto)
    repo = Foresight.Config.get(:engine, :repo, Foresight.Repo)
    embedder = Foresight.Config.get(:engine, :embedder, Foresight.Embedders.Noop)
    reranker = Foresight.Config.get(:engine, :reranker, Foresight.Rerankers.Passthrough)
    llm = Foresight.Config.get(:engine, :llm, Foresight.LLMs.LlmCore)
    queue = Foresight.Config.get(:engine, :queue, Foresight.AsyncQueues.Oban)

    with :ok <- TenantScope.validate_context(ctx, Map.get(args, "tenant_scope")),
         {:ok, result} <-
           storage.refresh_mental_model_operation(
             ctx,
             payload,
             AsyncOptions.restore(args,
               repo: repo,
               embedder: embedder,
               reranker: reranker,
               llm: llm,
               queue: queue
             )
           ) do
      # Best-effort meta write: a 0-row update must not trigger an Oban retry of an
      # already-committed refresh. See RetainWorker for the rationale.
      _ = persist_result(job_id, result, repo)
      :ok
    else
      {:error, reason} ->
        _ = persist_failure_result(job_id, reason, repo)
        {:error, reason}
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
