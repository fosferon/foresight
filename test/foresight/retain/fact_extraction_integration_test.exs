defmodule Foresight.Retain.FactExtractionIntegrationTest do
  @moduledoc """
  End-to-end proof that retain-time atomic-fact extraction fans one
  whole-session blob into N persisted, embedded memory units through the real
  retain pipeline (prepare → insert → entities → links) against real Postgres.

  Tagged :tier2 (PostgresHarness).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Schemas.Entity
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  # Splits any blob into three atomic facts with distinct content + one event.
  defmodule SplittingLLM do
    def complete_json_schema(_prompt, _messages, _schema, _opts) do
      {:ok,
       %{
         "facts" => [
           %{
             "what" => "User enrolled in a Spanish course",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "event",
             "occurred_start" => "2024-03-01",
             "occurred_end" => "2024-03-01",
             "fact_type" => "assistant",
             "entities" => ["Spanish course", "user"]
           },
           %{
             "what" => "User enrolled in a pottery course",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "event",
             "occurred_start" => "2024-03-02",
             "occurred_end" => "2024-03-02",
             "fact_type" => "assistant",
             "entities" => ["pottery course", "user"]
           },
           %{
             "what" => "User prefers evening classes",
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "conversation",
             "fact_type" => "world",
             "entities" => ["evening classes"]
           }
         ]
       }}
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
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)

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
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    on_exit(fn ->
      restore(:backend, original_backend)
      restore(:engine, original_engine)
    end)

    :ok
  end

  test "one blob fans out into N atomic memory units, each embedded, sharing the session's mentioned_at" do
    put_engine(SplittingLLM, "concise")
    ctx = %Context{tenant_id: "fx-tenant", mode: :mode_a, bank: "fx-bank"}

    session_date = "2024-03-15T00:00:00Z"

    {:ok, result} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [
          %{
            "id" => "session-1",
            "content" =>
              "user: I signed up for Spanish and pottery this month.\nassistant: nice! evenings?",
            "context" => "chat",
            "mentioned_at" => session_date,
            "tags" => ["source:test"]
          }
        ]
      })

    assert result["success"] == true

    units =
      Foresight.Repo.all(
        from(u in MemoryUnit, where: u.bank_id == ^ctx.bank, order_by: u.content)
      )

    # One input blob → three atomic units.
    assert length(units) == 3

    contents = Enum.map(units, & &1.content)
    assert "User enrolled in a Spanish course | Involving: user" in contents
    assert "User enrolled in a pottery course | Involving: user" in contents
    assert "User prefers evening classes | Involving: user" in contents

    # Blob text is NOT stored verbatim as a unit.
    refute Enum.any?(units, &String.contains?(&1.content, "I signed up for Spanish and pottery"))

    # Every atomic fact inherits the session's mentioned_at (temporal anchor for
    # cross-session reflect arithmetic) and is embedded (non-null vector).
    for u <- units do
      assert DateTime.to_date(u.mentioned_at) == ~D[2024-03-15]
      assert u.embedded_dim in [384, 1024]
      assert not is_nil(Map.get(u, :"embedding_#{u.embedded_dim}"))
      assert u.tags == ["source:test"]
    end

    # Event facts carry occurred dates; the conversation fact does not.
    events = Enum.filter(units, &String.contains?(&1.content, "enrolled"))
    convo = Enum.find(units, &String.contains?(&1.content, "evening classes"))
    assert Enum.all?(events, &(not is_nil(&1.occurred_start)))
    assert is_nil(convo.occurred_start)
  end

  test "materialized entities come from the LLM fact.entities, not a regex over content" do
    put_engine(SplittingLLM, "concise")
    ctx = %Context{tenant_id: "fx-ent-tenant", mode: :mode_a, bank: "fx-ent-bank"}

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [
          %{
            "id" => "session-ent",
            "content" => "user: I signed up for Spanish and pottery this month.",
            "context" => "chat",
            "mentioned_at" => "2024-03-15T00:00:00Z",
            "tags" => ["source:test"]
          }
        ]
      })

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    names = Enum.map(entities, & &1.canonical_name)

    # Multi-word entities the regex extractor (\b[A-Z][A-Za-z0-9_-]{2,}\b, single
    # tokens only) structurally cannot produce — proof the LLM entities are used.
    assert "Spanish course" in names
    assert "pottery course" in names
    assert "evening classes" in names

    # "Involving" appears in every fact's assembled text ("... | Involving: user")
    # and the regex WOULD have captured it; its absence proves content is not
    # re-scanned for entities when the LLM supplied them.
    refute "Involving" in names
    refute "User" in names

    # "user" appears in two facts → one deduped entity, mention_count 2.
    user_entity = Enum.find(entities, &(&1.normalized_name == "user"))
    assert user_entity
    assert user_entity.mention_count == 2
  end

  # One fact whose entities are supplied per-retain via :test_entities, so a test
  # can drive the exact mention sequence the resolver sees. All same-day (day1) so
  # temporal proximity contributes its full 0.2 to every candidate score.
  defmodule EntitiesLLM do
    def complete_json_schema(_prompt, _messages, _schema, _opts) do
      entities = Application.get_env(:foresight, :test_entities, [])

      names =
        Enum.map(entities, fn
          %{"name" => n} -> n
          %{"text" => t} -> t
          n when is_binary(n) -> n
        end)

      {:ok,
       %{
         "facts" => [
           %{
             "what" => "mention of " <> Enum.join(names, ", "),
             "who" => "user",
             "why" => "N/A",
             "fact_kind" => "event",
             "occurred_start" => "2024-03-01",
             "occurred_end" => "2024-03-01",
             "fact_type" => "assistant",
             "entities" => entities
           }
         ]
       }}
    end
  end

  test "fuzzy resolution: 'google inc' MERGES into 'Google' when co-occurrence corroborates" do
    ctx = %Context{tenant_id: "fx-fz-merge-tenant", mode: :mode_a, bank: "fx-fz-merge-bank"}

    # Retain 1 (day1): Google co-occurs with Android → seeds the Google↔Android link.
    retain_entities(ctx, "s1", ["Google", "Android"], "2024-03-01T00:00:00Z")
    # Retain 2 (day1): "google inc" is a substring candidate of "Google"; same-day
    # recency (0.2) + shared "Android" co-occurrence (0.3) lift its 0.375 name score
    # to 0.875 > 0.6 → merge, no distinct "google inc" entity.
    retain_entities(ctx, "s2", ["google inc", "Android"], "2024-03-01T00:00:00Z")

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    normalized = Enum.map(entities, & &1.normalized_name)

    assert "google" in normalized
    assert "android" in normalized
    refute "google inc" in normalized

    google = Enum.find(entities, &(&1.normalized_name == "google"))
    assert google.mention_count == 2
  end

  test "fuzzy resolution: 'google inc' stays DISTINCT from 'Google' without corroboration" do
    ctx = %Context{tenant_id: "fx-fz-create-tenant", mode: :mode_a, bank: "fx-fz-create-bank"}

    # No co-occurring entity in either retain, so the only signals are name (0.375)
    # and same-day recency (0.2) = 0.575, which does NOT clear the 0.6 threshold —
    # exactly Hindsight's SequenceMatcher boundary. Two distinct entities result.
    retain_entities(ctx, "s1", ["Google"], "2024-03-01T00:00:00Z")
    retain_entities(ctx, "s2", ["google inc"], "2024-03-01T00:00:00Z")

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    normalized = Enum.map(entities, & &1.normalized_name)

    assert "google" in normalized
    assert "google inc" in normalized
  end

  test "fuzzy resolution: typo variant 'Goggle' merges into 'Google' via pg_trgm recall" do
    ctx = %Context{tenant_id: "fx-trgm-tenant", mode: :mode_a, bank: "fx-trgm-bank"}

    retain_entities(ctx, "s1", ["Google", "Android"], "2024-03-01T00:00:00Z")
    # "Goggle" is NOT a substring of "Google", so the substring "full" strategy could
    # never surface it as a candidate. pg_trgm trigram similarity does. SequenceMatcher
    # then scores it 0.8333 → 0.4167 name + same-day 0.2 + shared "Android" 0.3 → merge.
    # This is the proof of fuzzy-variant RECALL parity, not just the fallback.
    retain_entities(ctx, "s2", ["Goggle", "Android"], "2024-03-01T00:00:00Z")

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    normalized = Enum.map(entities, & &1.normalized_name)

    assert "google" in normalized
    refute "goggle" in normalized

    google = Enum.find(entities, &(&1.normalized_name == "google"))
    assert google.mention_count == 2
  end

  test "fuzzy resolution fallback: forced :full strategy merges substrings but not non-substring typos" do
    Application.put_env(:foresight, :entity_lookup_strategy, :full)
    on_exit(fn -> Application.delete_env(:foresight, :entity_lookup_strategy) end)

    ctx = %Context{tenant_id: "fx-full-tenant", mode: :mode_a, bank: "fx-full-bank"}

    retain_entities(ctx, "s1", ["Google", "Android"], "2024-03-01T00:00:00Z")
    # "google inc" IS a substring relation to "Google", so the fallback surfaces it →
    # corroborated merge works even without pg_trgm.
    retain_entities(ctx, "s2", ["google inc", "Android"], "2024-03-01T00:00:00Z")
    # "Goggle" is NOT a substring of "Google": the substring fallback can never surface
    # it, so it stays distinct — exactly the degraded recall pg_trgm exists to fix.
    retain_entities(ctx, "s3", ["Goggle", "Android"], "2024-03-01T00:00:00Z")

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    normalized = Enum.map(entities, & &1.normalized_name)

    refute "google inc" in normalized
    assert "goggle" in normalized
  end

  test "semantic recall: 'NYC' merges into 'New York City' via embedding similarity" do
    Application.put_env(:foresight, :entity_semantic_recall, true)
    on_exit(fn -> Application.delete_env(:foresight, :entity_semantic_recall) end)
    emb = Foresight.TestSupport.SemanticEmbedder

    ctx = %Context{tenant_id: "fx-sem-tenant", mode: :mode_a, bank: "fx-sem-bank"}

    retain_entities(ctx, "s1", ["New York City", "Android"], "2024-03-01T00:00:00Z", emb)
    # "NYC" is neither a substring nor trigram-similar to "New York City", so ONLY the
    # semantic arm can surface it. Its name embedding shares a cluster with
    # "New York City" (cosine 1.0 → name 0.5); + shared "Android" co-occurrence (0.3)
    # (+ same-day 0.2) clears 0.6 → merge. This is recall Hindsight structurally lacks.
    retain_entities(ctx, "s2", ["NYC", "Android"], "2024-03-01T00:00:00Z", emb)

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    normalized = Enum.map(entities, & &1.normalized_name)

    assert "new york city" in normalized
    refute "nyc" in normalized

    nyc = Enum.find(entities, &(&1.normalized_name == "new york city"))
    assert nyc.mention_count == 2
  end

  test "semantic recall OFF (default): 'NYC' stays distinct from 'New York City' (parity)" do
    emb = Foresight.TestSupport.SemanticEmbedder
    ctx = %Context{tenant_id: "fx-nosem-tenant", mode: :mode_a, bank: "fx-nosem-bank"}

    # Same inputs and embedder, but the flag is off, so no semantic arm runs and NYC —
    # not substring/trigram of "New York City" — cannot resolve to it. Proves the merge
    # above is the semantic arm's doing, and that default behavior is unchanged parity.
    retain_entities(ctx, "s1", ["New York City", "Android"], "2024-03-01T00:00:00Z", emb)
    retain_entities(ctx, "s2", ["NYC", "Android"], "2024-03-01T00:00:00Z", emb)

    entities = Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
    normalized = Enum.map(entities, & &1.normalized_name)

    assert "new york city" in normalized
    assert "nyc" in normalized
  end

  test "typed entities: entity_type stored per entity, untyped defaults CONCEPT" do
    Application.put_env(:foresight, :test_entities, [
      %{"name" => "Emily", "type" => "person"},
      %{"name" => "Acme Corp", "type" => "org"},
      "wedding"
    ])

    on_exit(fn -> Application.delete_env(:foresight, :test_entities) end)
    put_engine(EntitiesLLM, "concise")

    ctx = %Context{tenant_id: "fx-typed-tenant", mode: :mode_a, bank: "fx-typed-bank"}

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [
          %{
            "id" => "s1",
            "content" => "user: Emily married at the wedding; Acme Corp catered.",
            "context" => "chat",
            "mentioned_at" => "2024-06-09T00:00:00Z",
            "tags" => ["source:test"]
          }
        ]
      })

    types_by_name =
      Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
      |> Map.new(&{&1.normalized_name, &1.entity_type})

    # LLM-supplied types are carried through and upcased; the untyped entity defaults to
    # CONCEPT — the type Hindsight forces on ALL entities (entity_processing.py:32).
    assert types_by_name["emily"] == "PERSON"
    assert types_by_name["acme corp"] == "ORG"
    assert types_by_name["wedding"] == "CONCEPT"
  end

  test "extraction OFF (default) stores the whole blob as one unit (passthrough preserved)" do
    put_engine(SplittingLLM, nil)
    ctx = %Context{tenant_id: "fx-off-tenant", mode: :mode_a, bank: "fx-off-bank"}

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [
          %{
            "id" => "s1",
            "content" => "user: I signed up for Spanish and pottery.",
            "context" => "chat",
            "mentioned_at" => "2024-03-15T00:00:00Z",
            "tags" => ["source:test"]
          }
        ]
      })

    units = Foresight.Repo.all(from(u in MemoryUnit, where: u.bank_id == ^ctx.bank))
    assert length(units) == 1
    assert String.contains?(hd(units).content, "I signed up for Spanish and pottery")
  end

  # Entity-extractor LLM for the extraction-OFF path: returns entity NAMES (the seam's
  # {"entities": [...]} schema), not facts. "Barcelona" is absent from the retained
  # content, so its presence proves the LLM extractor ran — the regex Simple could
  # never invent it.
  defmodule EntityNamesLLM do
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:ok, %{"entities" => ["Barcelona", "Spanish course"]}}
  end

  test "extraction OFF + EntityExtractors.LLM: entities come from the LLM, not the regex" do
    # Extraction off → the item keeps its blob and carries no fact.entities, so the
    # seam consults the configured :entity_extractor. Wiring EntityExtractors.LLM +
    # engine :llm must materialize the LLM's entities — proof extractor_opts threads
    # the :llm handle through materialize_entities → EntityExtractor.run → extract/2.
    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: EntityNamesLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing,
      retain_extraction_mode: nil,
      entity_extractor: Foresight.EntityExtractors.LLM
    )

    ctx = %Context{tenant_id: "fx-llmext-tenant", mode: :mode_a, bank: "fx-llmext-bank"}

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [
          %{
            "id" => "s1",
            "content" => "user: loved my trip, signed up for classes.",
            "context" => "chat",
            "mentioned_at" => "2024-03-15T00:00:00Z",
            "tags" => ["source:test"]
          }
        ]
      })

    names =
      Foresight.Repo.all(from(e in Entity, where: e.bank_id == ^ctx.bank))
      |> Enum.map(& &1.canonical_name)

    assert "Barcelona" in names
    assert "Spanish course" in names

    # Extraction genuinely off: the blob is stored as a single unit, not atomized.
    units = Foresight.Repo.all(from(u in MemoryUnit, where: u.bank_id == ^ctx.bank))
    assert length(units) == 1
  end

  defp put_engine(llm, extraction_mode, embedder \\ Foresight.TestSupport.FakeEmbedder) do
    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: embedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: llm,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing,
      retain_extraction_mode: extraction_mode
    )
  end

  # Drive one retain whose sole fact carries exactly `entities`, at `mentioned_at`.
  defp retain_entities(
         ctx,
         id,
         entities,
         mentioned_at,
         embedder \\ Foresight.TestSupport.FakeEmbedder
       ) do
    Application.put_env(:foresight, :test_entities, entities)
    put_engine(EntitiesLLM, "concise", embedder)

    {:ok, res} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [
          %{
            "id" => id,
            "content" => "user: mentioning " <> Enum.join(entities, ", "),
            "context" => "chat",
            "mentioned_at" => mentioned_at,
            "tags" => ["source:test"]
          }
        ]
      })

    assert res["success"] == true
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
