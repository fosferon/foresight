defmodule Foresight.Evals.Dataset do
  @moduledoc """
  The dataset-adapter seam for the honest evaluation harness.

  Every eval dataset — LongMemEval now, a license-clean BEIR slice later — is normalised to
  a list of `Instance`s so the runner and the ranking metrics are dataset-agnostic. An
  adapter's only job is to turn its native format into `Instance`s; nothing downstream
  knows or cares which corpus it came from.

  An `Instance` carries everything the runner needs and nothing it doesn't:

    * `memories` — retain-ready maps (each with a stable `"id"`, mirrored into
      `metadata["eval_id"]` so recall results can be mapped back to their label).
    * `relevance` — graded gain per memory id (0 irrelevant … n ideal). Scoring reads ids
      and labels only, never answer text, so a corpus phrase earns nothing.
    * `reference_answer` / `abstention?` — for grading reflect (a correct answer, or a
      correct refusal when the evidence is absent).
  """

  @enforce_keys [:id, :query, :memories, :relevance]
  defstruct id: nil,
            query: nil,
            query_timestamp: nil,
            question_type: nil,
            memories: [],
            relevance: %{},
            reference_answer: nil,
            abstention?: false

  @type t :: %__MODULE__{
          id: String.t(),
          query: String.t(),
          query_timestamp: String.t() | nil,
          question_type: String.t() | nil,
          memories: [map()],
          relevance: %{optional(String.t()) => number()},
          reference_answer: String.t() | nil,
          abstention?: boolean()
        }

  @doc """
  Stamp each memory's stable `"id"` into `metadata["eval_id"]` so recall results (which
  echo metadata) can be mapped back to their relevance label. Idempotent.
  """
  @spec label_memories([map()]) :: [map()]
  def label_memories(memories) do
    Enum.map(memories, fn m ->
      id = m["id"] || m[:id]
      metadata = Map.merge(%{"eval_id" => id}, m["metadata"] || %{})
      Map.put(m, "metadata", metadata)
    end)
  end

  @doc "Extract the ranked list of eval ids from a recall response's results."
  @spec ranked_eval_ids([map()]) :: [String.t()]
  def ranked_eval_ids(results) when is_list(results) do
    results
    |> Enum.map(fn r -> get_in(r, ["metadata", "eval_id"]) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Inject `k` distractor memories into each instance, sampled deterministically from the
  memories of *other* instances (relevance 0). This turns an evidence-only split (where
  every candidate is relevant, so retrieval is trivial) into a distractor-heavy retrieval
  task — the setting the full LongMemEval haystack provides natively. Distractor ids are
  namespaced so they never collide with, or accidentally become, a relevant id.

  Deterministic in `seed`: no wall-clock or global RNG, so the eval is reproducible.
  """
  @spec pool_distractors([t()], pos_integer(), integer()) :: [t()]
  def pool_distractors(instances, k, seed \\ 1) when k > 0 do
    pool =
      instances
      |> Enum.flat_map(fn inst -> Enum.map(inst.memories, &{inst.id, &1}) end)

    pool_size = length(pool)

    instances
    |> Enum.with_index()
    |> Enum.map(fn {inst, idx} ->
      chosen =
        pick_distractors(pool, pool_size, k, seed + idx, inst.id)
        |> Enum.map(fn {origin, mem} -> as_distractor(mem, origin) end)

      %{
        inst
        | memories: inst.memories ++ chosen,
          relevance: Enum.reduce(chosen, inst.relevance, &Map.put(&2, &1["id"], 0))
      }
    end)
  end

  # Deterministic index walk (a fixed-step LCG-style probe) over the pool; skips any memory
  # that originates from the current instance so we never demote a real candidate to noise.
  defp pick_distractors(_pool, 0, _k, _seed, _self_id), do: []

  defp pick_distractors(pool, pool_size, k, seed, self_id) do
    step = 2_654_435_761

    Stream.iterate(rem(seed * step, pool_size), &rem(&1 + step, pool_size))
    |> Stream.map(&Enum.at(pool, rem(abs(&1), pool_size)))
    |> Stream.reject(fn {origin, _mem} -> origin == self_id end)
    |> Stream.uniq_by(fn {origin, mem} -> {origin, mem["id"]} end)
    |> Enum.take(k)
  end

  defp as_distractor(mem, origin) do
    id = "distractor:#{origin}:#{mem["id"]}"

    mem
    |> Map.put("id", id)
    |> Map.put("metadata", Map.merge(mem["metadata"] || %{}, %{"eval_id" => id}))
  end
end
