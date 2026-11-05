defmodule Foresight.Evals.Labeling.LabelStoreTest do
  @moduledoc """
  Persists human + llm label attrs into labeled_pairs, idempotently
  (re-running a labeling pass upserts on (bank_id, query_ref, memory_ref, source) rather than
  duplicating). Real Postgres via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Evals.Labeling.LabelStore
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.LabeledPair
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2

  @bank_id "bank_eval_store"

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 5)
    )

    start_supervised!(Foresight.Repo)
    migrations_path = Path.expand("../../../../priv/repo/migrations", __DIR__)

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
    Foresight.Repo.delete_all(LabeledPair)
    Foresight.Repo.delete_all(from(b in Bank, where: b.id == ^@bank_id))
    Foresight.Repo.insert!(Bank.changeset(%Bank{}, %{id: @bank_id, name: "eval store"}))
    :ok
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        bank_id: @bank_id,
        query_ref: "q1",
        query_text: "when did I renew my passport?",
        memory_ref: "m1",
        grade: 3,
        source: :human,
        split: :calibration
      },
      overrides
    )
  end

  test "writes human and llm labels and reports the count" do
    result =
      LabelStore.write_all([
        attrs(%{source: :human, grade: 3}),
        attrs(%{source: :llm, grade: 2, judge_model: "zai/glm-5.2"})
      ])

    assert result.written == 2
    assert result.errors == []
    assert Foresight.Repo.aggregate(LabeledPair, :count) == 2
  end

  test "re-writing the same (pair, source) upserts instead of duplicating" do
    LabelStore.write_all([attrs(%{source: :human, grade: 3})])
    LabelStore.write_all([attrs(%{source: :human, grade: 1})])

    rows = Foresight.Repo.all(LabeledPair)
    assert length(rows) == 1
    assert hd(rows).grade == 1
  end

  test "the same stable pair refs can be labeled independently in different banks" do
    other_bank_id = "bank_eval_store_other"

    Foresight.Repo.insert!(
      Bank.changeset(%Bank{}, %{id: other_bank_id, name: "other eval store"})
    )

    result =
      LabelStore.write_all([
        attrs(%{grade: 3}),
        attrs(%{bank_id: other_bank_id, grade: 1})
      ])

    assert result == %{written: 2, errors: []}
    assert Foresight.Repo.aggregate(LabeledPair, :count) == 2
  end

  test "collects invalid attrs as errors without aborting the batch" do
    result =
      LabelStore.write_all([
        attrs(%{source: :human, grade: 2}),
        attrs(%{query_ref: "q_bad", source: :human, grade: 9})
      ])

    assert result.written == 1
    assert length(result.errors) == 1
    assert Foresight.Repo.aggregate(LabeledPair, :count) == 1
  end
end
