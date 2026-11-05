defmodule Foresight.Evals.Labeling.GoldSet do
  @moduledoc """
  Relevance-labeling pipeline, gold-set step: build the human-graded gold set from per-query candidate pools
  and serialize it to a gradeable artifact.

  `build/2` selects a stratified sample of (query, candidate) pairs (balanced across
  question types), deterministically under a seed, caps how many pairs any one query
  contributes, and assigns each pair a `:calibration` split (co-graded by the LLM judge →
  Cohen's kappa) or a `:test` split (held out from fusion-weight training, so the final evaluation metric
  rests on human labels). `to_artifact/2` renders the selection to a JSON-encodable map
  whose `"grade"` fields are blank for the human to fill.

  Determinism mirrors the LongMemEval stratified sampler: `:rand.seed(:exsss, {s, s*7, s*13})`.
  Pure: no DB, no recall call.
  """

  @default_seed 42
  @default_target 150
  @default_per_query_cap 10
  @default_calibration_ratio 0.4

  # One-line grading rubric, repeated inline on every row so it's in front of the grader
  # at the point of judgement.
  @rubric "Grade 0-3 for relevance to the question — 3: directly answers / essential · " <>
            "2: clearly relevant, partial support · 1: weakly / tangentially related · " <>
            "0: irrelevant. Judge relevance only, not correctness."

  @type gold_pair :: %{
          query_ref: String.t(),
          query_text: String.t(),
          question_type: String.t() | nil,
          memory_ref: String.t(),
          content: String.t() | nil,
          context: String.t() | nil,
          split: :calibration | :test
        }

  @doc """
  Build the gold set from `query_pools` (each `%{query_ref, query_text, question_type,
  candidates: [pooled candidate]}`).

  Options: `:seed`, `:target_pairs`, `:per_query_cap`, `:calibration_ratio`.
  """
  @spec build([map()], keyword()) :: [gold_pair()]
  def build(query_pools, opts \\ []) do
    seed = Keyword.get(opts, :seed, @default_seed)
    target = Keyword.get(opts, :target_pairs, @default_target)
    per_query_cap = Keyword.get(opts, :per_query_cap, @default_per_query_cap)
    calibration_ratio = Keyword.get(opts, :calibration_ratio, @default_calibration_ratio)

    :rand.seed(:exsss, {seed, seed * 7, seed * 13})

    query_pools
    |> flatten_pairs(per_query_cap)
    |> stratified_take(target)
    |> assign_splits(calibration_ratio)
  end

  @doc "Render a built gold set to a JSON-encodable artifact with blank grades."
  @spec to_artifact([gold_pair()], String.t()) :: map()
  def to_artifact(gold_pairs, bank_id) do
    %{
      "version" => 1,
      "bank_id" => bank_id,
      "pairs" =>
        Enum.map(gold_pairs, fn p ->
          %{
            "pair_id" => "#{p.query_ref}::#{p.memory_ref}",
            "query_ref" => p.query_ref,
            "query_text" => p.query_text,
            "question_type" => p.question_type,
            "memory_ref" => p.memory_ref,
            "content" => p.content,
            "context" => p.context,
            "split" => Atom.to_string(p.split),
            "rubric" => @rubric,
            "grade" => nil,
            "notes" => ""
          }
        end)
    }
  end

  defp flatten_pairs(query_pools, per_query_cap) do
    Enum.flat_map(query_pools, fn q ->
      q.candidates
      |> Enum.take(per_query_cap)
      |> Enum.map(fn c ->
        %{
          query_ref: q.query_ref,
          query_text: q.query_text,
          question_type: q.question_type,
          memory_ref: c.memory_ref,
          content: c[:content],
          context: c[:context]
        }
      end)
    end)
  end

  # Balanced take across question types (ceil per type, then trim to target), each type's
  # group shuffled under the active seed.
  defp stratified_take(pairs, target) do
    grouped = Enum.group_by(pairs, & &1.question_type)
    num_types = max(map_size(grouped), 1)
    per_type = ceil(target / num_types)

    grouped
    |> Enum.sort_by(fn {type, _} -> to_string(type) end)
    |> Enum.flat_map(fn {_type, group} -> group |> Enum.shuffle() |> Enum.take(per_type) end)
    |> Enum.take(target)
  end

  # Shuffle then slice so calibration doesn't correlate with question-type ordering.
  defp assign_splits(pairs, calibration_ratio) do
    shuffled = Enum.shuffle(pairs)
    calibration_count = round(calibration_ratio * length(shuffled))

    shuffled
    |> Enum.with_index()
    |> Enum.map(fn {pair, idx} ->
      split = if idx < calibration_count, do: :calibration, else: :test
      Map.put(pair, :split, split)
    end)
  end
end
