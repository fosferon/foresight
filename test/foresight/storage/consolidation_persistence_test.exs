defmodule Foresight.Storage.ConsolidationPersistenceTest do
  @moduledoc """
  Verifies the consolidation parity port: the LLM `creates`/`updates`/
  `deletes` merge engine, real (non-zero) observation embeddings, proof_count and
  source-union semantics on update, `consolidated_at` stamping of processed
  sources, and degrade-safety when the LLM is unavailable.

  Uses a real Postgres (pgvector) via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Storage.ConsolidationPersistence, as: CP
  alias Foresight.TestSupport.FakeLLM
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  @bank_id "consolidation-parity-test"
  @dim 384

  defmodule FailingLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(_prompt, _messages, _module, _opts), do: {:error, :unavailable}

    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts), do: {:error, :unavailable}
  end

  # Emits a CREATE citing a source_fact_id not in the batch (hallucinated).
  defmodule HallucinatedCreateLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(_prompt, _messages, _module, _opts), do: {:ok, %{}}

    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts) do
      {:ok,
       %{
         "creates" => [
           %{"text" => "ghost", "source_fact_ids" => ["00000000-0000-0000-0000-000000000000"]}
         ],
         "updates" => [],
         "deletes" => []
       }}
    end
  end

  # Emits a DELETE and an UPDATE for the SAME observation id (the collision that
  # would otherwise raise Ecto.StaleEntryError and abort the batch).
  defmodule DeleteAndUpdateSameIdLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    def put_target(id), do: Process.put(__MODULE__, id)

    @impl true
    def complete_structured(_prompt, _messages, _module, _opts), do: {:ok, %{}}

    @impl true
    def complete_json_schema(prompt, _messages, _schema, _opts) do
      id = Process.get(__MODULE__)
      fact_ids = Enum.map(prompt[:facts] || [], &(&1["id"] || &1[:id]))

      {:ok,
       %{
         "creates" => [],
         "updates" => [
           %{"observation_id" => id, "text" => "revised", "source_fact_ids" => fact_ids}
         ],
         "deletes" => [%{"observation_id" => id}]
       }}
    end
  end

  # Emits a single delete for a target observation id (supersession path).
  defmodule DeleteObservationLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    def put_target(id), do: Process.put(__MODULE__, id)

    @impl true
    def complete_structured(_prompt, _messages, _module, _opts), do: {:ok, %{}}

    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts) do
      {:ok,
       %{
         "creates" => [],
         "updates" => [],
         "deletes" => [%{"observation_id" => Process.get(__MODULE__)}]
       }}
    end
  end

  # Returns a valid CREATE wrapped in a ```json fence with a trailing comma — the
  # exact structured-output failure mode Ollama-served models produce, which was
  # silently skipping every consolidation (0 observations) before the fix.
  defmodule FencedCreateLLM do
    @moduledoc false
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(_prompt, _messages, _module, _opts), do: {:ok, %{}}

    @impl true
    def complete_json_schema(prompt, _messages, _schema, _opts) do
      ids = Enum.map(prompt[:facts] || [], &(&1["id"] || &1[:id]))
      id_json = ids |> Enum.map(&"\"#{&1}\"") |> Enum.join(", ")

      raw = """
      ```json
      {
        "creates": [
          {"text": "alice likes tea and coffee", "source_fact_ids": [#{id_json}]},
        ],
        "updates": [],
        "deletes": []
      }
      ```
      """

      {:error, {:structured_output_error, {:invalid_json, %{data: raw}}}}
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
    :ok
  end

  test "creates a single merged, non-zero-embedded observation from a scope's facts" do
    a = insert_fact!("alice likes tea", ["user:alice"])
    b = insert_fact!("alice likes coffee", ["user:alice"])

    observations = consolidate_scope!(FakeLLM, "user:alice", [a, b], [])

    assert [obs] = observations
    assert obs.fact_type == :observation
    assert obs.content =~ "alice likes tea"
    assert obs.content =~ "alice likes coffee"
    # CREATE writes proof_count=1 (Hindsight parity), sources are the two facts.
    assert obs.proof_count == 1
    assert MapSet.new(obs.source_memory_ids) == MapSet.new([a.id, b.id])

    # The zero-vector bug is fixed: the observation is embedded and recallable.
    refute zero_vector?(obs.embedding_384)
    assert obs.embedded_by != "consolidation" or obs.embedded_dim == @dim

    # Sources are stamped so they are not reprocessed.
    assert reload(a.id).consolidated_at != nil
    assert reload(b.id).consolidated_at != nil
  end

  test "re-consolidation UPDATES the existing observation: proof_count grows, sources union, history appended" do
    a = insert_fact!("alice likes tea", ["user:alice"])
    [obs] = consolidate_scope!(FakeLLM, "user:alice", [a], [])
    assert obs.proof_count == 1

    # A new fact arrives in the same scope; the pool now holds the observation,
    # so FakeLLM issues an UPDATE folding both facts in.
    b = insert_fact!("alice likes coffee", ["user:alice"])
    existing = CP.pool_observations(Foresight.Repo, @bank_id, "user:alice", [])
    assert length(existing) == 1

    [updated] = consolidate_scope!(FakeLLM, "user:alice", [b], existing)

    assert updated.id == obs.id
    assert updated.content =~ "alice likes coffee"
    # UPDATE proof_count = len(union of prior + new source ids).
    assert MapSet.new(updated.source_memory_ids) == MapSet.new([a.id, b.id])
    assert updated.proof_count == 2
    assert [%{"previous_text" => _} | _] = updated.metadata["history"]
    refute zero_vector?(updated.embedding_384)
  end

  test "recovers a ```json-fenced/trailing-comma merge response and still writes the observation" do
    a = insert_fact!("alice likes tea", ["user:alice"])
    b = insert_fact!("alice likes coffee", ["user:alice"])

    # Previously this fenced body failed the strict parse → {:skip} → zero
    # observations. Recovery decodes it and the merge proceeds normally.
    observations = consolidate_scope!(FencedCreateLLM, "user:alice", [a, b], [])

    assert [obs] = observations
    assert obs.fact_type == :observation
    assert obs.content =~ "alice likes tea and coffee"
    assert MapSet.new(obs.source_memory_ids) == MapSet.new([a.id, b.id])
    refute zero_vector?(obs.embedding_384)
    assert reload(a.id).consolidated_at != nil
  end

  test "is degrade-safe when the LLM is unavailable: no observations, sources stay pending" do
    a = insert_fact!("bob likes tea", ["user:bob"])

    assert {:skip, _reason} =
             CP.prepare_scope(
               FailingLLM,
               Foresight.Embedders.Noop,
               bank(),
               "user:bob",
               [a],
               [],
               []
             )

    assert CP.pool_observations(Foresight.Repo, @bank_id, "user:bob", []) == []
    # Not stamped — a real LLM can process it on a later run.
    assert reload(a.id).consolidated_at == nil
  end

  test "consolidation_groups only returns unconsolidated facts" do
    a = insert_fact!("fresh fact", ["topic"])
    _consolidated = insert_fact!("already done", ["topic"], DateTime.utc_now())

    {:ok, groups} = CP.consolidation_groups(Foresight.Repo, @bank_id, %{}, [])
    ids = groups |> Enum.flat_map(fn {_scope, units} -> Enum.map(units, & &1.id) end)

    assert a.id in ids
    refute Enum.any?(ids, &(reload(&1).content == "already done"))
  end

  test "a create citing only hallucinated source facts is skipped (no orphan observation)" do
    a = insert_fact!("real fact", ["topic"])

    observations = consolidate_scope!(HallucinatedCreateLLM, "topic", [a], [])

    # No live source facts resolved → no observation written...
    assert observations == []
    assert CP.pool_observations(Foresight.Repo, @bank_id, "topic", []) == []
    # ...but the LLM call succeeded, so the real source fact is still stamped.
    assert reload(a.id).consolidated_at != nil
  end

  test "a delete and an update for the same observation id does not crash the batch (delete wins)" do
    a = insert_fact!("alice likes tea", ["user:alice"])
    [obs] = consolidate_scope!(FakeLLM, "user:alice", [a], [])

    DeleteAndUpdateSameIdLLM.put_target(to_string(obs.id))
    b = insert_fact!("alice likes coffee", ["user:alice"])
    existing = CP.pool_observations(Foresight.Repo, @bank_id, "user:alice", [])

    # Must not raise Ecto.StaleEntryError; the update targeting the deleted id is dropped.
    written = consolidate_scope!(DeleteAndUpdateSameIdLLM, "user:alice", [b], existing)

    assert written == []
    assert CP.pool_observations(Foresight.Repo, @bank_id, "user:alice", []) == []
  end

  test "supersession: a consolidation delete supersedes the observation (kept + edge), not destroys it" do
    a = insert_fact!("alice likes tea", ["user:alice"])
    [obs] = consolidate_scope!(FakeLLM, "user:alice", [a], [])

    DeleteObservationLLM.put_target(to_string(obs.id))
    b = insert_fact!("alice no longer likes tea", ["user:alice"])
    existing = CP.pool_observations(Foresight.Repo, @bank_id, "user:alice", [])

    written = consolidate_scope!(DeleteObservationLLM, "user:alice", [b], existing)
    assert written == []

    # The observation is KEPT but marked superseded (non-destructive; beats hard-delete)
    # and thus dropped from the active merge pool.
    reloaded = reload(obs.id)
    assert reloaded != nil
    assert reloaded.superseded_at != nil
    assert CP.pool_observations(Foresight.Repo, @bank_id, "user:alice", []) == []

    # A `supersedes` edge records that the new fact superseded the observation.
    edges =
      Foresight.Repo.all(
        from(l in Foresight.Schemas.MemoryLink,
          where: l.to_unit_id == ^obs.id and l.link_type == "supersedes"
        )
      )

    assert Enum.any?(edges, &(&1.from_unit_id == b.id))
  end

  # --- helpers ---

  defp consolidate_scope!(llm, scope_key, units, existing) do
    assert {:ok, prepared} =
             CP.prepare_scope(
               llm,
               Foresight.Embedders.Noop,
               bank(),
               scope_key,
               units,
               existing,
               []
             )

    Foresight.Repo.transaction(fn ->
      CP.apply_prepared!(Foresight.Repo, bank(), prepared, [])
    end)
    |> then(fn {:ok, observations} -> observations end)
  end

  defp bank, do: %{id: @bank_id, mission: nil, config_overrides: %{}}

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

  defp insert_fact!(content, tags, consolidated_at \\ nil) do
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
      mentioned_at: now,
      consolidated_at: consolidated_at
    }

    %MemoryUnit{}
    |> MemoryUnit.changeset(attrs)
    |> Foresight.Repo.insert!()
  end

  defp reload(id), do: Foresight.Repo.get!(MemoryUnit, id)

  defp unit_vector do
    0.0 |> List.duplicate(@dim) |> List.replace_at(0, 1.0) |> Pgvector.new()
  end

  defp zero_vector?(nil), do: true

  defp zero_vector?(vector) do
    vector |> Pgvector.to_list() |> Enum.all?(&(&1 == 0.0))
  end
end
