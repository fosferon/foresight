defmodule Foresight.Storage.Consolidation do
  @moduledoc """
  Consolidation orchestration. Phase A (pool existing observations, run the LLM
  merge, embed results) runs OUTSIDE the DB transaction; Phase B applies the
  prepared writes, stamps sources, and refreshes mental models INSIDE one
  transaction. This keeps slow LLM/embedding IO off the tenant DB connection
  (the reflect txn-across-LLM pool-timeout class of bug).

  Faithful port of Hindsight's `consolidator.py` batching:

  * Chunked merging — each scope's pending facts are split into `consolidation_llm_batch_size`
    chunks and merged one chunk per LLM call, instead of cramming the whole scope
    into a single oversized prompt. Chunks are processed sequentially and each
    commits before the next, so a create from an earlier chunk is re-pooled as an
    existing observation for later chunks (consolidator.py:360-364).
  * Draining — a drain loop keeps fetching and processing pending groups until none
    remain (consolidator.py:324 `while True`), so tail facts beyond the first
    fetch slice still become observations.
  * Bisection and quarantine — on an LLM merge failure a sub-batch is bisected down to size 1; a
    single fact that still fails is quarantined via `consolidation_failed_at`
    (consolidator.py:382-513), so the rest of a batch still consolidates and a
    poison fact is not retried forever.

  The Phase-A-outside-txn / Phase-B-inside-txn discipline is preserved at CHUNK
  granularity: each chunk's LLM/embed work happens outside the txn, and only that
  chunk's writes run inside a (per-chunk) transaction — mirroring Hindsight's
  per-batch commits for crash recovery.
  """

  require Logger

  alias Foresight.Error
  alias Foresight.Storage.ConsolidationPersistence

  # Hard safety cap on drain rounds. Every non-empty round terminally stamps at
  # least one fact, so the loop is bounded by pending-fact count anyway; this
  # only guards against a pathological no-progress state.
  @max_rounds 1_000

  def consolidate(ctx, %{"async" => true} = payload, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.enqueue_consolidate(ctx, payload, opts)
  end

  def consolidate(ctx, payload, opts, callbacks) when is_map(payload) do
    repo = Keyword.fetch!(opts, :repo)
    llm = Keyword.get(opts, :llm, Foresight.LLMs.Noop)
    embedder = Keyword.get(opts, :embedder, Foresight.Embedders.Noop)
    repo_opts = callbacks.repo_opts.(ctx)
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, bank} <- callbacks.fetch_bank.(repo, ctx.bank, repo_opts) do
      base = %{
        ctx: ctx,
        bank: bank,
        bank_id: ctx.bank,
        llm: llm,
        embedder: embedder,
        opts: opts,
        callbacks: callbacks,
        repo: repo,
        repo_opts: repo_opts,
        payload: payload,
        batch_size: ConsolidationPersistence.llm_batch_size(bank)
      }

      acc0 = %{
        written: 0,
        stamped: 0,
        failed: 0,
        stale: 0,
        scopes_seen: MapSet.new(),
        scopes_consolidated: MapSet.new()
      }

      case drain(base, 1, acc0) do
        {:ok, acc} ->
          result = %{
            "success" => true,
            "bank_id" => ctx.bank,
            "observations_created" => acc.written,
            "facts_quarantined" => acc.failed,
            "chunks_deferred" => acc.stale,
            "scopes_consolidated" => MapSet.size(acc.scopes_consolidated),
            "scopes_seen" => MapSet.size(acc.scopes_seen),
            "operation" => "consolidate"
          }

          case callbacks.audit_log.(
                 repo,
                 ctx,
                 "consolidate",
                 payload,
                 result,
                 repo_opts,
                 started_at
               ) do
            {:ok, _audit_log} -> {:ok, result}
            {:error, %Error{} = error} -> {:error, error}
          end

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  # ---- drain loop ------------------------------------------------------------

  defp drain(_base, round, acc) when round > @max_rounds do
    Logger.warning("consolidation drain hit round cap #{@max_rounds}; stopping")
    {:ok, acc}
  end

  defp drain(base, round, acc) do
    case base.callbacks.consolidation_groups.(
           base.repo,
           base.bank_id,
           base.payload,
           base.repo_opts
         ) do
      {:ok, []} ->
        {:ok, acc}

      {:ok, groups} ->
        round_acc = process_round(base, groups, acc)

        # Progress guard: a round that terminally stamped nothing (e.g. every
        # chunk hit a DB apply error) must not spin forever — stop instead. A round
        # that deferred stale chunks is different: a concurrent run is making the
        # progress, so re-fetch and plan again from its committed state.
        if round_acc.stamped == acc.stamped and round_acc.stale == acc.stale do
          {:ok, round_acc}
        else
          drain(base, round + 1, round_acc)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp process_round(base, groups, acc) do
    Enum.reduce(groups, acc, fn {scope_key, units}, acc ->
      chunks = Enum.chunk_every(units, base.batch_size)

      group_res =
        Enum.reduce(
          chunks,
          %{written: 0, stamped: 0, failed: 0, stale: 0, success: false},
          fn chunk, gacc -> merge_chunk_results(gacc, process_chunk(base, scope_key, chunk)) end
        )

      %{
        acc
        | written: acc.written + group_res.written,
          stamped: acc.stamped + group_res.stamped,
          failed: acc.failed + group_res.failed,
          stale: acc.stale + group_res.stale,
          scopes_seen: MapSet.put(acc.scopes_seen, scope_key),
          scopes_consolidated:
            if(group_res.success,
              do: MapSet.put(acc.scopes_consolidated, scope_key),
              else: acc.scopes_consolidated
            )
      }
    end)
  end

  # ---- per-chunk processing with adaptive bisection ---------------------------

  defp process_chunk(base, scope_key, chunk) do
    # Re-pool per chunk so an earlier chunk's committed creates are visible as
    # existing observations to this one (Hindsight's sequential batch state).
    existing =
      base.callbacks.pool_observations.(base.repo, base.bank_id, scope_key, base.repo_opts)

    source_facts = resolve_source_facts(base, existing)

    prepared =
      ConsolidationPersistence.prepare_scope(
        base.llm,
        base.embedder,
        base.bank,
        scope_key,
        chunk,
        existing,
        base.opts,
        source_facts
      )

    case prepared do
      {:ok, plan} ->
        apply_chunk(base, scope_key, chunk, plan)

      {:skip, reason} when length(chunk) > 1 ->
        {left, right} = Enum.split(chunk, div(length(chunk), 2))

        Logger.warning(
          "consolidation sub-batch of #{length(chunk)} facts failed " <>
            "(#{inspect(reason)}); bisecting #{length(left)}/#{length(right)}"
        )

        merge_chunk_results(
          process_chunk(base, scope_key, left),
          process_chunk(base, scope_key, right)
        )

      {:skip, reason} ->
        # size 1 and still failing → quarantine the poison fact.
        [unit] = chunk

        Logger.warning(
          "consolidation quarantining fact #{inspect(unit.id)} after persistent " <>
            "merge failure: #{inspect(reason)}"
        )

        base.callbacks.stamp_failed.(base.repo, [unit.id], base.repo_opts)
        %{written: 0, stamped: 1, failed: 1, stale: 0, success: false}
    end
  end

  # Phase B for one chunk: apply writes + stamp sources + refresh mental model
  # inside a single (per-chunk) transaction.
  defp apply_chunk(base, scope_key, chunk, plan) do
    chunk_ids = Enum.map(chunk, & &1.id)

    base.repo.transaction(
      fn ->
        # Serialise with every other writer of this scope, then confirm the plan is
        # still valid. Phase A ran outside the transaction, so a concurrent run may
        # have consolidated some of these facts or changed the pooled observations
        # the merge was built against; applying the plan anyway would duplicate
        # observations or overwrite the other run's update. Skip it and let the next
        # round re-plan from committed state.
        lock_scope(base).(base.repo, base.bank_id, scope_key, base.repo_opts)

        pending =
          pending_unit_ids(base).(base.repo, chunk_ids, base.repo_opts)
          |> Enum.map(&pending_id/1)
          |> MapSet.new()

        pooled =
          base.callbacks.pool_observations.(base.repo, base.bank_id, scope_key, base.repo_opts)

        if Enum.any?(chunk_ids, &(not MapSet.member?(pending, &1))) do
          base.repo.rollback({:stale_chunk, :facts_already_consolidated})
        end

        if ConsolidationPersistence.observation_fingerprint(pooled) != plan.existing do
          base.repo.rollback({:stale_chunk, :observations_changed})
        end

        written = base.callbacks.apply_prepared.(base.repo, base.bank, plan, base.repo_opts)

        scope_observations =
          base.callbacks.pool_observations.(base.repo, base.bank_id, scope_key, base.repo_opts)

        base.callbacks.refresh_mental_model.(
          base.repo,
          base.bank,
          scope_key,
          scope_observations,
          chunk,
          base.repo_opts
        )

        written
      end,
      base.repo_opts
    )
    |> case do
      {:ok, written} ->
        %{written: length(written), stamped: length(chunk), failed: 0, stale: 0, success: true}

      {:error, {:stale_chunk, why}} ->
        Logger.info(
          "consolidation chunk for scope #{inspect(scope_key)} (#{length(chunk)} facts) " <>
            "deferred: #{why} by a concurrent run; re-planning next round"
        )

        %{written: 0, stamped: 0, failed: 0, stale: 1, success: false}

      {:error, reason} ->
        # A DB apply failure leaves this chunk's facts unstamped (retryable) but
        # must not be silently swallowed as progress.
        Logger.warning(
          "consolidation apply failed for scope #{inspect(scope_key)} " <>
            "(#{length(chunk)} facts): #{inspect(reason)}"
        )

        %{written: 0, stamped: 0, failed: 0, stale: 0, success: false}
    end
  end

  defp pending_id(%{id: id}), do: id
  defp pending_id(id), do: id

  # Optional callbacks: storages that cannot take a Postgres advisory lock run
  # unguarded, as before; the pool fingerprint check still applies.
  defp lock_scope(base),
    do: Map.get(base.callbacks, :lock_scope, fn _repo, _bank_id, _scope, _opts -> :ok end)

  defp pending_unit_ids(base),
    do: Map.get(base.callbacks, :pending_unit_ids, fn _repo, ids, _opts -> ids end)

  defp resolve_source_facts(base, existing) do
    ids = Enum.flat_map(existing, &(&1.source_memory_ids || []))

    base.callbacks.resolve_source_facts.(base.repo, base.bank_id, ids, base.repo_opts)
  end

  defp merge_chunk_results(a, b) do
    %{
      written: a.written + b.written,
      stamped: a.stamped + b.stamped,
      failed: a.failed + b.failed,
      stale: a.stale + b.stale,
      success: a.success or b.success
    }
  end
end
