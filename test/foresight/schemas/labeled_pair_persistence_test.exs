defmodule Foresight.Schemas.LabeledPairPersistenceTest do
  @moduledoc """
  Proves the labeled_pairs migration applies and the constraint semantics
  that make the kappa join and per-source grading work: a human and an llm label for the
  SAME (query_ref, memory_ref) coexist, while a second label from the same source is
  rejected. Real Postgres via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.LabeledPair
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2

  @bank_id "bank_eval_labels"

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
    Foresight.Repo.delete_all(LabeledPair)
    Foresight.Repo.delete_all(from(b in Bank, where: b.id == ^@bank_id))
    Foresight.Repo.insert!(Bank.changeset(%Bank{}, %{id: @bank_id, name: "eval labels"}))
    :ok
  end

  defp label!(attrs) do
    %LabeledPair{}
    |> LabeledPair.changeset(Map.merge(base_attrs(), attrs))
    |> Foresight.Repo.insert()
  end

  defp base_attrs do
    %{
      bank_id: @bank_id,
      query_ref: "q_0001",
      query_text: "When did I renew my passport?",
      memory_ref: "session_42",
      grade: 3,
      source: :human,
      split: :calibration
    }
  end

  test "a human and an llm label for the same pair coexist (the kappa join surface)" do
    assert {:ok, human} = label!(%{source: :human})

    assert {:ok, judged} =
             label!(%{source: :llm, judge_model: "zai/glm-5.2", grade: 2})

    rows = Foresight.Repo.all(from(l in LabeledPair, where: l.memory_ref == "session_42"))
    assert length(rows) == 2
    assert human.source == :human and human.grade == 3
    assert judged.source == :llm and judged.grade == 2 and judged.judge_model == "zai/glm-5.2"
  end

  test "a second label from the same source for the same pair is rejected" do
    assert {:ok, _} = label!(%{source: :human})
    assert {:error, changeset} = label!(%{source: :human, grade: 1})
    assert Keyword.has_key?(changeset.errors, :query_ref)
  end

  test "grade and enum fields round-trip through the database" do
    assert {:ok, inserted} =
             label!(%{source: :llm, judge_model: "zai/glm-5.2", split: :train, grade: 0})

    reloaded = Foresight.Repo.get!(LabeledPair, inserted.id)
    assert reloaded.grade == 0
    assert reloaded.source == :llm
    assert reloaded.split == :train
  end

  test "labels are cascade-deleted with their bank" do
    assert {:ok, _} = label!(%{source: :human})
    Foresight.Repo.delete_all(from(b in Bank, where: b.id == ^@bank_id))
    assert Foresight.Repo.all(LabeledPair) == []
  end
end
