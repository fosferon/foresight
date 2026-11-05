defmodule Foresight.Storage.LinkConstructionTest do
  @moduledoc """
  Verifies retain-time construction of the memory_links graph:
  semantic edges from pgvector kNN and temporal edges from event-time proximity.

  Uses a real Postgres (pgvector) via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Schemas.MemoryLink
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Storage.LinkConstruction
  alias Foresight.TestSupport.FakeAsyncQueue
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  @bank_id "link-construction-test"
  @dim 384

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 5)
    )

    start_supervised!(Foresight.Repo)
    start_supervised!({FakeAsyncQueue, []})

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
    # Fresh graph per test; delete links then units (FK order), then reinsert the bank.
    Foresight.Repo.delete_all(MemoryLink)
    Foresight.Repo.delete_all(from(u in MemoryUnit, where: u.bank_id == ^@bank_id))
    upsert_bank!()
    # Clear the embedding-profile pin between tests: the module reuses one
    # bank across tests that legitimately use different embedder models (synthetic
    # "test-embedder" vectors vs a real "BAAI/..." embedding), so a pin set by one
    # test must not leak into the next and trip the enforce_bank_embedding_profile
    # trigger. Each test then establishes its own pin on first insert.
    Foresight.Repo.update_all(
      from(b in "banks", where: b.id == ^@bank_id),
      set: [embedding_dim: nil, embedding_model: nil]
    )

    :ok
  end

  test "builds semantic links between similar units and none between dissimilar ones" do
    t0 = ~U[2026-01-01 12:00:00.000000Z]

    # a and b share an identical embedding (cosine sim 1.0 >= 0.7 threshold);
    # c is orthogonal to both (sim 0.0), so it forms no semantic edge.
    a = insert_unit!("a", vec_at(0), t0)
    b = insert_unit!("b", vec_at(0), t0)
    c = insert_unit!("c", vec_at(1), t0)

    {:ok, _count} = LinkConstruction.build_links(Foresight.Repo, @bank_id, [a, b, c], [])

    semantic = links_of_type("semantic")
    pairs = Enum.map(semantic, &{&1.from_unit_id, &1.to_unit_id}) |> MapSet.new()

    assert MapSet.member?(pairs, {a.id, b.id})
    assert MapSet.member?(pairs, {b.id, a.id})

    refute Enum.any?(semantic, fn link -> link.to_unit_id == c.id or link.from_unit_id == c.id end)

    ab = Enum.find(semantic, &(&1.from_unit_id == a.id and &1.to_unit_id == b.id))
    assert_in_delta ab.weight, 1.0, 1.0e-4
  end

  test "builds temporal links within the 24h window and none outside it" do
    t0 = ~U[2026-01-01 12:00:00.000000Z]

    # near is 1h from a (inside 24h); far is 100h away (outside). All orthogonal
    # embeddings so temporal edges are isolated from semantic ones.
    a = insert_unit!("a", vec_at(0), t0)
    near = insert_unit!("near", vec_at(1), DateTime.add(t0, 3600, :second))
    far = insert_unit!("far", vec_at(2), DateTime.add(t0, 100 * 3600, :second))

    {:ok, _count} = LinkConstruction.build_links(Foresight.Repo, @bank_id, [a, near, far], [])

    temporal = links_of_type("temporal")
    pairs = Enum.map(temporal, &{&1.from_unit_id, &1.to_unit_id}) |> MapSet.new()

    assert MapSet.member?(pairs, {a.id, near.id})
    assert MapSet.member?(pairs, {near.id, a.id})

    refute Enum.any?(temporal, fn link ->
             link.to_unit_id == far.id or link.from_unit_id == far.id
           end)

    # weight decays with distance: 1h apart -> 1 - 1/24 ≈ 0.958
    a_near = Enum.find(temporal, &(&1.from_unit_id == a.id and &1.to_unit_id == near.id))
    assert_in_delta a_near.weight, 1.0 - 1.0 / 24.0, 1.0e-3
  end

  test "is a no-op for units without embeddings (Noop-embedder retains never fail)" do
    t0 = ~U[2026-01-01 12:00:00.000000Z]
    a = insert_unit!("a", nil, t0)
    b = insert_unit!("b", nil, t0)

    {:ok, count} = LinkConstruction.build_links(Foresight.Repo, @bank_id, [a, b], [])

    # No embeddings -> no semantic links; same timestamp still yields temporal links.
    assert links_of_type("semantic") == []
    assert count == length(links_of_type("temporal"))
  end

  test "the retain sync path builds semantic links end-to-end via the post-commit hook" do
    # Two identical-content items get identical (deterministic) Noop embeddings,
    # so cosine similarity is 1.0 and a semantic edge MUST be created. Proves the
    # post-commit hook actually fires on the real retain path with populated
    # embeddings — not just that build_links works when handed units directly.
    ctx = %Foresight.Context{tenant_id: "default", mode: :mode_a, bank: @bank_id}

    items = [
      %{"content" => "the quick brown fox jumps", "context" => "c"},
      %{"content" => "the quick brown fox jumps", "context" => "c"}
    ]

    assert {:ok, _result} =
             Foresight.Storage.Ecto.retain(
               ctx,
               %{"items" => items, "async" => false},
               repo: Foresight.Repo,
               embedder: Foresight.Embedders.Noop,
               queue: FakeAsyncQueue
             )

    assert length(links_of_type("semantic")) >= 2
  end

  # --- helpers ---

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

  defp insert_unit!(content, vec, occurred_at) do
    attrs = %{
      bank_id: @bank_id,
      fact_type: :experience,
      content: content,
      context: "test",
      embedded_by: "test-embedder",
      embedded_dim: @dim,
      embedding_384: vec,
      occurred_at: occurred_at,
      mentioned_at: occurred_at
    }

    %MemoryUnit{}
    |> MemoryUnit.changeset(attrs)
    |> Foresight.Repo.insert!()
  end

  defp vec_at(index) do
    0.0
    |> List.duplicate(@dim)
    |> List.replace_at(index, 1.0)
    |> Pgvector.new()
  end

  defp links_of_type(link_type) do
    Foresight.Repo.all(
      from(l in MemoryLink, where: l.bank_id == ^@bank_id and l.link_type == ^link_type)
    )
  end
end
