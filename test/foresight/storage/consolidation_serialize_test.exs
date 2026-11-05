defmodule Foresight.Storage.ConsolidationSerializeTest do
  @moduledoc """
  Pure-logic coverage for the observation serialization that feeds the
  consolidation LLM prompt: each pooled observation must
  carry its `mentioned_at` AND a `source_memories` array (the supporting facts'
  text + dates) so the model makes better UPDATE-vs-CREATE facet decisions —
  mirroring Hindsight's `_build_observations_for_llm`.
  """
  use ExUnit.Case, async: true

  alias Foresight.Prompts.Consolidation.V1, as: ConsolidationPrompt
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Storage.ConsolidationPersistence, as: CP

  test "serialize_observations includes mentioned_at and source_memories text" do
    mentioned = ~U[2025-03-20 10:00:00.000000Z]
    src_start = ~U[2025-03-15 09:00:00.000000Z]

    source = %MemoryUnit{
      id: "11111111-1111-1111-1111-111111111111",
      content: "alice sold her Honda Civic",
      context: "chat",
      occurred_start: src_start,
      mentioned_at: mentioned
    }

    obs = %MemoryUnit{
      id: "22222222-2222-2222-2222-222222222222",
      content: "Alice owns a 2019 Honda Civic",
      proof_count: 1,
      source_memory_ids: ["11111111-1111-1111-1111-111111111111"],
      mentioned_at: mentioned
    }

    [serialized] =
      CP.serialize_observations([obs], %{"11111111-1111-1111-1111-111111111111" => source})

    assert serialized["id"] == "22222222-2222-2222-2222-222222222222"
    assert serialized["mentioned_at"]
    assert [%{"text" => "alice sold her Honda Civic"} = sm] = serialized["source_memories"]
    assert sm["context"] == "chat"

    # And the rendered prompt section carries the source-memory text through.
    rendered = ConsolidationPrompt.format_observations([serialized])
    assert rendered =~ "alice sold her Honda Civic"
    assert rendered =~ "source_memories"
  end

  test "serialize_observations omits source_memories when there are no resolvable sources" do
    obs = %MemoryUnit{
      id: "33333333-3333-3333-3333-333333333333",
      content: "standalone observation",
      proof_count: 1,
      source_memory_ids: [],
      mentioned_at: nil
    }

    [serialized] = CP.serialize_observations([obs], %{})

    refute Map.has_key?(serialized, "source_memories")
    refute Map.has_key?(serialized, "mentioned_at")
  end

  test "proof_count floors at 1 (audit F3, Hindsight `len(...) or 1`)" do
    # nil proof_count AND no sources would compute 0 — must serialize as 1.
    obs = %MemoryUnit{
      id: "44444444-4444-4444-4444-444444444444",
      content: "legacy observation with no recorded sources",
      proof_count: nil,
      source_memory_ids: []
    }

    [serialized] = CP.serialize_observations([obs], %{})
    assert serialized["proof_count"] == 1
  end
end
