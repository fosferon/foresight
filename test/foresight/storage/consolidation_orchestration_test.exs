defmodule Foresight.Storage.ConsolidationOrchestrationTest do
  @moduledoc """
  Orchestration-level parity coverage for the consolidation port:

  * Chunked merging — a scope with more facts than `consolidation_llm_batch_size` is merged in
    multiple LLM calls, and an earlier chunk's create is visible as an existing
    observation to later chunks.
  * Draining — a single `consolidate` call drains ALL pending facts across multiple
    fetch rounds, not just the first slice.
  * Bisection and quarantine — a reliably-failing fact is bisected out and quarantined via
    `consolidation_failed_at`; the rest of the batch still consolidates and the
    poison fact is excluded from the next pending fetch.

  Drives `Foresight.Storage.Consolidation.consolidate/4` directly against a real
  Postgres (pgvector) with test callbacks — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Storage.Consolidation
  alias Foresight.Storage.ConsolidationPersistence, as: CP
  alias Foresight.TestSupport.FakeLLM
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  @bank_id "consolidation-orchestration-test"
  @dim 384

  # Counts consolidation merge calls (prompt query == "consolidate") in the test
  # process dictionary — Phase A is synchronous in the caller process.
  defmodule CountingMergeLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, module, opts),
      do: FakeLLM.complete_structured(prompt, messages, module, opts)

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      if prompt[:query] == "consolidate" do
        Process.put(:merge_calls, Process.get(:merge_calls, 0) + 1)
      end

      FakeLLM.complete_json_schema(prompt, messages, schema, opts)
    end
  end

  # Fails the merge whenever a "POISON" fact is in the batch; otherwise delegates
  # to FakeLLM. Models a fact that reliably breaks the LLM structured output.
  defmodule PoisonFactLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, module, opts),
      do: FakeLLM.complete_structured(prompt, messages, module, opts)

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      facts = prompt[:facts] || []

      if Enum.any?(facts, &String.contains?(&1["content"] || "", "POISON")) do
        {:error, :poison_fact}
      else
        FakeLLM.complete_json_schema(prompt, messages, schema, opts)
      end
    end
  end

  # Records the system prompt and response schema the merge was called with, then
  # delegates to FakeLLM — lets a test see the capacity note and the creates cap.
  defmodule CapturingLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, module, opts),
      do: FakeLLM.complete_structured(prompt, messages, module, opts)

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      if prompt[:query] == "consolidate" do
        system = Enum.find_value(messages, fn %{role: :system, content: c} -> c end)
        Process.put(:merge_calls_seen, [{system, schema} | Process.get(:merge_calls_seen, [])])
      end

      FakeLLM.complete_json_schema(prompt, messages, schema, opts)
    end
  end

  # Emits ONE create referencing only the FIRST fact of each batch, leaving the
  # rest unreferenced — models a real model that does not emit a source_fact_id
  # for every input fact. The whole processed batch must still be stamped
  # consolidated (Hindsight marks the entire sub_batch, consolidator.py:499),
  # else the drain loop re-fetches the unreferenced facts and re-merges them into
  # a fresh observation every round.
  defmodule FirstFactOnlyLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, module, opts),
      do: FakeLLM.complete_structured(prompt, messages, module, opts)

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      if match?(%{"properties" => %{"creates" => _, "updates" => _, "deletes" => _}}, schema) do
        facts = prompt[:facts] || []
        first_id = facts |> List.first() |> then(&(&1 && (&1["id"] || &1[:id])))
        text = facts |> Enum.map(&(&1["content"] || &1[:content])) |> Enum.join(" | ")

        creates =
          if first_id, do: [%{"text" => text, "source_fact_ids" => [first_id]}], else: []

        {:ok, %{"creates" => creates, "updates" => [], "deletes" => []}}
      else
        FakeLLM.complete_json_schema(prompt, messages, schema, opts)
      end
    end
  end

  # Fails the merge for the first two attempts, then succeeds — models a transient
  # structured-output hiccup. With the ported `consolidation_max_attempts` (default
  # 3) retry loop, the batch succeeds on attempt 3 and is NOT bisected/quarantined.
  defmodule FlakyThenOkLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(prompt, messages, module, opts),
      do: FakeLLM.complete_structured(prompt, messages, module, opts)

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) do
      if match?(%{"properties" => %{"creates" => _, "updates" => _, "deletes" => _}}, schema) do
        n = (Process.get(:merge_attempts) || 0) + 1
        Process.put(:merge_attempts, n)

        if n <= 2,
          do: {:error, :transient_json_hiccup},
          else: FakeLLM.complete_json_schema(prompt, messages, schema, opts)
      else
        FakeLLM.complete_json_schema(prompt, messages, schema, opts)
      end
    end
  end

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 5)
    )

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    Foresight.Repo.delete_all(from(u in MemoryUnit, where: u.bank_id == ^@bank_id))
    upsert_bank!()
    Process.delete(:merge_calls)
    :ok
  end

  defp upsert_bank!() do
    Foresight.Repo.insert_all(
      "banks",
      [
        %{
          id: @bank_id,
          name: @bank_id,
          mission: "",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:id]
    )
  end

  test "chunked merging: a scope larger than llm_batch_size is merged in multiple calls, and an early create is visible to later chunks" do
    # llm_batch_size = 2 via bank override → 5 facts across ceil(5/2) = 3 chunks.
    facts =
      for i <- 1..5, do: insert_fact!("alice likes item #{i}", ["user:alice"])

    bank = bank(%{"consolidation_llm_batch_size" => 2})

    assert {:ok, result} =
             Consolidation.consolidate(ctx(), %{}, opts(CountingMergeLLM), callbacks(bank))

    assert result["success"] == true
    # >1 merge call proves per-chunk batching (was a single whole-scope call).
    assert Process.get(:merge_calls) >= 3

    # All facts consolidated across the chunks.
    assert Enum.all?(facts, &(reload(&1.id).consolidated_at != nil))

    # One canonical observation whose sources union ALL chunks' facts — only
    # possible if chunk 1's create was re-pooled and UPDATEd by chunks 2 and 3.
    assert [obs] = observations("user:alice")
    assert MapSet.new(obs.source_memory_ids) == MapSet.new(Enum.map(facts, & &1.id))
    assert obs.proof_count == 5
  end

  test "draining: a single consolidate call drains all pending facts across multiple rounds" do
    # Fetch batch size = 3 (engine override) but 7 pending facts → 3 rounds.
    original_engine = Application.get_env(:foresight, :engine)
    Application.put_env(:foresight, :engine, consolidation_batch_size: 3)
    on_exit(fn -> restore_env(:engine, original_engine) end)

    facts = for i <- 1..7, do: insert_fact!("bob detail #{i}", ["user:bob"])

    assert {:ok, result} =
             Consolidation.consolidate(ctx(), %{}, opts(FakeLLM), callbacks(bank()))

    assert result["success"] == true
    # Every fact — including the tail beyond the first fetch slice — is consolidated.
    assert Enum.all?(facts, &(reload(&1.id).consolidated_at != nil))
    assert [_obs] = observations("user:bob")

    # Nothing left pending.
    {:ok, groups} = CP.consolidation_groups(Foresight.Repo, @bank_id, %{}, [])
    assert groups == []
  end

  test "quarantine: a reliably-failing fact is quarantined while the rest of the batch consolidates" do
    good_a = insert_fact!("carol likes tea", ["user:carol"])
    poison = insert_fact!("POISON breaks the model", ["user:carol"])
    good_b = insert_fact!("carol likes coffee", ["user:carol"])
    good_c = insert_fact!("carol likes cake", ["user:carol"])

    assert {:ok, result} =
             Consolidation.consolidate(ctx(), %{}, opts(PoisonFactLLM), callbacks(bank()))

    assert result["success"] == true
    # the quarantined poison fact is surfaced in the result (audit F3 dead-field fix)
    assert result["facts_quarantined"] == 1

    # The good facts still consolidate.
    assert reload(good_a.id).consolidated_at != nil
    assert reload(good_b.id).consolidated_at != nil
    assert reload(good_c.id).consolidated_at != nil
    assert [_obs] = observations("user:carol")

    # The poison fact is quarantined, not consolidated.
    poison_reloaded = reload(poison.id)
    assert poison_reloaded.consolidation_failed_at != nil
    assert poison_reloaded.consolidated_at == nil

    # ...and excluded from the next pending fetch (no infinite retry).
    {:ok, groups} = CP.consolidation_groups(Foresight.Repo, @bank_id, %{}, [])
    pending_ids = groups |> Enum.flat_map(fn {_s, us} -> Enum.map(us, & &1.id) end)
    refute poison.id in pending_ids
  end

  test "the whole processed batch is stamped consolidated even when the LLM references only some facts" do
    # 4 facts, single chunk (batch_size 8). The LLM references only the first —
    # the other three are unreferenced. All four must still be marked consolidated
    # so the drain terminates in one round with exactly one observation, rather
    # than re-fetching facts 2-4 and re-merging them into fresh observations.
    facts = for i <- 1..4, do: insert_fact!("dave detail #{i}", ["user:dave"])
    bank = bank(%{"consolidation_llm_batch_size" => 8})

    assert {:ok, _result} =
             Consolidation.consolidate(ctx(), %{}, opts(FirstFactOnlyLLM), callbacks(bank))

    # Every fact in the batch — not just the referenced one — is consolidated.
    assert Enum.all?(facts, &(reload(&1.id).consolidated_at != nil))
    # Exactly ONE observation (the buggy whole-batch-not-stamped path re-merges the
    # unreferenced facts into a new observation each drain round).
    assert [_obs] = observations("user:dave")
    # Nothing left pending.
    {:ok, groups} = CP.consolidation_groups(Foresight.Repo, @bank_id, %{}, [])
    assert groups == []
  end

  test "F1: a transient merge failure is retried up to max_attempts before bisection — no quarantine" do
    Process.delete(:merge_attempts)
    facts = for i <- 1..3, do: insert_fact!("erin note #{i}", ["user:erin"])

    # Default max_attempts = 3: attempts 1-2 fail, attempt 3 succeeds, so the whole
    # batch consolidates in one merge — no fact is bisected out or quarantined.
    assert {:ok, result} =
             Consolidation.consolidate(ctx(), %{}, opts(FlakyThenOkLLM), callbacks(bank()))

    assert result["facts_quarantined"] == 0
    assert Enum.all?(facts, &(reload(&1.id).consolidated_at != nil))
    assert Enum.all?(facts, &(reload(&1.id).consolidation_failed_at == nil))
    assert [_obs] = observations("user:erin")
  end

  # --- helpers ---

  test "the merge prompt carries the capacity note and the creates cap near the scope limit" do
    insert_fact!("erin plays chess", ["user:erin"])
    insert_fact!("erin plays go", ["user:erin"])
    bank = bank(%{"max_observations_per_scope" => 1})

    assert {:ok, _} = Consolidation.consolidate(ctx(), %{}, opts(CapturingLLM), callbacks(bank))

    assert [{system, schema}] = Process.get(:merge_calls_seen)
    assert system =~ "## CAPACITY CONSTRAINT"
    assert system =~ "1 observation slot(s) remaining (out of 1)"
    assert get_in(schema, ["properties", "creates", "maxItems"]) == 1
    assert [_obs] = observations("user:erin")

    # Scope now full: the note flips to LIMIT REACHED and no create is allowed.
    Process.delete(:merge_calls_seen)
    insert_fact!("erin plays shogi", ["user:erin"])

    assert {:ok, _} = Consolidation.consolidate(ctx(), %{}, opts(CapturingLLM), callbacks(bank))

    assert [{system, schema}] = Process.get(:merge_calls_seen)
    assert system =~ "OBSERVATION LIMIT REACHED (1/1)"
    assert get_in(schema, ["properties", "creates", "maxItems"]) == 0
    assert [_obs] = observations("user:erin")
  end

  test "a chunk whose facts a concurrent run consolidated is deferred, not applied" do
    facts = for i <- 1..3, do: insert_fact!("frank fact #{i}", ["user:frank"])

    # Models the other run: by the time this run takes the scope lock, every fact
    # of the chunk has been stamped by someone else (on its own connection, so the
    # stamp is committed and survives this run's rollback).
    concurrent_stamp = fn _repo, ids, _repo_opts ->
      Task.async(fn -> CP.stamp_consolidated!(Foresight.Repo, ids, []) end)
      |> Task.await()

      []
    end

    callbacks = Map.put(callbacks(bank()), :pending_unit_ids, concurrent_stamp)

    assert {:ok, result} = Consolidation.consolidate(ctx(), %{}, opts(FakeLLM), callbacks)

    assert result["chunks_deferred"] >= 1
    assert result["observations_created"] == 0
    assert observations("user:frank") == []
    assert Enum.all?(facts, &(reload(&1.id).consolidated_at != nil))
  end

  test "two concurrent consolidate runs on one bank write one observation and stamp each fact once" do
    facts = for i <- 1..6, do: insert_fact!("grace detail #{i}", ["user:grace"])
    bank = bank(%{"consolidation_llm_batch_size" => 2})

    callbacks =
      callbacks(bank)
      |> Map.put(:lock_scope, &CP.lock_scope/4)
      |> Map.put(:pending_unit_ids, &CP.pending_unit_ids/3)

    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> Consolidation.consolidate(ctx(), %{}, opts(FakeLLM), callbacks) end)
      end)
      |> Task.await_many(60_000)

    assert Enum.all?(results, &match?({:ok, %{"success" => true}}, &1))
    assert Enum.all?(facts, &(reload(&1.id).consolidated_at != nil))

    # Without the scope lock + stale-plan check both runs created observations for
    # the same facts.
    assert [obs] = observations("user:grace")
    assert MapSet.new(obs.source_memory_ids) == MapSet.new(Enum.map(facts, & &1.id))
    assert obs.proof_count == 6

    {:ok, groups} = CP.consolidation_groups(Foresight.Repo, @bank_id, %{}, [])
    assert groups == []
  end

  defp ctx, do: %Foresight.Context{tenant_id: "t", mode: :mode_a, bank: @bank_id}

  defp opts(llm) do
    [repo: Foresight.Repo, llm: llm, embedder: Foresight.Embedders.Noop]
  end

  defp bank(config_overrides \\ %{}) do
    %{id: @bank_id, mission: nil, config_overrides: config_overrides}
  end

  defp callbacks(bank) do
    %{
      repo_opts: fn _ctx -> [] end,
      fetch_bank: fn _repo, _bank_id, _opts -> {:ok, bank} end,
      consolidation_groups: &CP.consolidation_groups/4,
      pool_observations: &CP.pool_observations/4,
      resolve_source_facts: &CP.resolve_source_facts/4,
      apply_prepared: fn repo, bnk, plan, opts -> CP.apply_prepared!(repo, bnk, plan, opts) end,
      stamp_failed: &CP.stamp_consolidation_failed!/3,
      refresh_mental_model: fn _repo, _bank, _scope, _obs, _units, _opts -> :ok end,
      audit_log: fn _repo, _ctx, _action, _payload, result, _opts, _started -> {:ok, result} end
    }
  end

  defp observations(scope_key), do: CP.pool_observations(Foresight.Repo, @bank_id, scope_key, [])

  defp insert_fact!(content, tags) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      bank_id: @bank_id,
      fact_type: :experience,
      content: content,
      context: "test",
      tags: tags,
      embedded_by: "test-embedder",
      embedded_dim: @dim,
      embedding_384: unit_vector(),
      occurred_at: now,
      mentioned_at: now
    }

    %MemoryUnit{}
    |> MemoryUnit.changeset(attrs)
    |> Foresight.Repo.insert!()
  end

  defp reload(id), do: Foresight.Repo.get!(MemoryUnit, id)

  defp unit_vector do
    0.0 |> List.duplicate(@dim) |> List.replace_at(0, 1.0) |> Pgvector.new()
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)
end
