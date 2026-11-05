defmodule Foresight.Tenancy.BankEmbeddingProfileTest do
  @moduledoc """
  Verifies the DB-level "one embedding profile per bank" invariant: the
  first embedded write pins banks.embedding_dim/embedding_model; matching writes are
  accepted; a mismatched dim/model is physically rejected by the trigger, so a bank
  can never mix embedding dimensions regardless of application code.

  Real Postgres via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  @bank_id "embedding-profile-test"

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
    Foresight.Repo.delete_all(from(b in Bank, where: b.id == ^@bank_id))
    upsert_bank!()
    :ok
  end

  test "first embedded write pins the bank profile; matching writes are accepted" do
    assert %Bank{embedding_dim: nil, embedding_model: nil} = reload_bank()

    insert_memory!(384, "bge-small", :embedding_384)
    pinned = reload_bank()
    assert pinned.embedding_dim == 384
    assert pinned.embedding_model == "bge-small"

    # A second write with the same profile is fine.
    insert_memory!(384, "bge-small", :embedding_384)

    assert Foresight.Repo.aggregate(from(u in MemoryUnit, where: u.bank_id == ^@bank_id), :count) ==
             2
  end

  test "a mismatched dimension is physically rejected by the trigger" do
    insert_memory!(384, "bge-small", :embedding_384)

    assert_raise Postgrex.Error, ~r/pinned to embedding profile/, fn ->
      insert_memory!(1024, "bge-small", :embedding_1024)
    end

    # The rejected write left no row and did not change the pin.
    assert Foresight.Repo.aggregate(from(u in MemoryUnit, where: u.bank_id == ^@bank_id), :count) ==
             1

    assert reload_bank().embedding_dim == 384
  end

  test "a mismatched model on the same dimension is rejected" do
    insert_memory!(384, "bge-small", :embedding_384)

    assert_raise Postgrex.Error, ~r/pinned to embedding profile/, fn ->
      insert_memory!(384, "other-model", :embedding_384)
    end
  end

  test "clearing the pin allows re-pinning to a new profile (supports bank re-embedding)" do
    insert_memory!(384, "bge-small", :embedding_384)
    assert reload_bank().embedding_dim == 384

    # This is what reset_bank_embedding_pin/3 does when a bank's embedding profile
    # changes, before the re-embedding backfill runs. Without it the trigger would
    # reject every re-embed and wedge the bank.
    Foresight.Repo.update_all(
      from(b in Bank, where: b.id == ^@bank_id),
      set: [embedding_dim: nil, embedding_model: nil]
    )

    # A write at the NEW profile now re-pins instead of being rejected.
    insert_memory!(1024, "text-embedding-3", :embedding_1024)
    pinned = reload_bank()
    assert pinned.embedding_dim == 1024
    assert pinned.embedding_model == "text-embedding-3"
  end

  # --- helpers ---

  defp insert_memory!(dim, model, vector_field) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    vector = 1.0 |> List.duplicate(dim) |> Pgvector.new()

    attrs =
      %{
        bank_id: @bank_id,
        fact_type: :world,
        content: "content #{System.unique_integer([:positive])}",
        context: "test",
        embedded_by: model,
        embedded_dim: dim,
        occurred_at: now,
        mentioned_at: now
      }
      |> Map.put(vector_field, vector)

    %MemoryUnit{}
    |> MemoryUnit.changeset(attrs)
    |> Foresight.Repo.insert!()
  end

  defp reload_bank, do: Foresight.Repo.get!(Bank, @bank_id)

  defp upsert_bank!() do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Foresight.Repo.insert_all(
      "banks",
      [%{id: @bank_id, name: @bank_id, mission: "", inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: [:id]
    )
  end
end
