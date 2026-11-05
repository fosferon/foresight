defmodule Foresight.Evals.Labeling.Generator do
  @moduledoc false

  alias Foresight.Context
  alias Foresight.Evals.Dataset
  alias Foresight.Evals.Labeling.GoldSet

  @default_seed 42
  @default_per_type 5
  @default_target_pairs 150
  @default_calibration_ratio 0.267
  @default_per_query_cap 10
  @default_top_k 20

  @spec generate([Dataset.t()], keyword()) :: {:ok, map()} | {:error, map()}
  def generate(instances, opts) when is_list(instances) do
    bank_id = Keyword.fetch!(opts, :bank_id)
    seed = Keyword.get(opts, :seed, @default_seed)
    per_type = Keyword.get(opts, :per_type, @default_per_type)
    top_k = Keyword.get(opts, :top_k, @default_top_k)
    concurrency = Keyword.get(opts, :concurrency, 1)

    prepare = Keyword.get(opts, :prepare, fn _ctx -> {:ok, %{}} end)
    retain = Keyword.get(opts, :retain, &retain/2)
    consolidate = Keyword.get(opts, :consolidate, &consolidate/1)
    recall = Keyword.get(opts, :recall, &recall/2)

    sampled = stratified_sample(instances, per_type, seed)

    with {:ok, query_pools, dropped_count} <-
           build_query_pools(
             sampled,
             bank_id,
             top_k,
             concurrency,
             prepare,
             retain,
             consolidate,
             recall
           ) do
      gold =
        GoldSet.build(query_pools,
          seed: seed,
          target_pairs: Keyword.get(opts, :target_pairs, @default_target_pairs),
          calibration_ratio: Keyword.get(opts, :calibration_ratio, @default_calibration_ratio),
          per_query_cap: Keyword.get(opts, :per_query_cap, @default_per_query_cap)
        )

      {:ok,
       %{
         artifact: GoldSet.to_artifact(gold, bank_id),
         query_pools: query_pools,
         sampled_instances: sampled,
         dropped_count: dropped_count
       }}
    end
  end

  defp build_query_pools(
         instances,
         bank_id,
         top_k,
         concurrency,
         prepare,
         retain,
         consolidate,
         recall
       ) do
    instances
    |> Task.async_stream(
      &build_query_pool(&1, bank_id, top_k, prepare, retain, consolidate, recall),
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.zip(instances)
    |> Enum.reduce_while({:ok, [], 0}, fn
      {{:ok, {:ok, query_pool, dropped_count}}, _instance}, {:ok, pools, total_dropped} ->
        {:cont, {:ok, [query_pool | pools], total_dropped + dropped_count}}

      {{:ok, {:error, error}}, _instance}, _acc ->
        {:halt, {:error, error}}

      {{:exit, reason}, instance}, _acc ->
        {:halt, {:error, stage_error(instance.id, :orchestration, reason)}}
    end)
    |> reverse_pools()
  end

  defp build_query_pool(instance, bank_id, top_k, prepare, retain, consolidate, recall) do
    query_bank = query_bank_id(bank_id, instance.id)
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: query_bank}
    memories = Dataset.label_memories(instance.memories)

    with {:prepare, {:ok, _prepare_result}} <- {:prepare, prepare.(ctx)},
         {:retain, {:ok, _retain_result}} <- {:retain, retain.(ctx, memories)},
         {:consolidate, {:ok, _consolidate_result}} <- {:consolidate, consolidate.(ctx)},
         {:recall, {:ok, %{"candidate_pool" => pool}}} <-
           {:recall, recall.(ctx, recall_payload(instance, top_k))} do
      candidates = pool_value(pool, :candidates, "candidates", [])
      dropped = pool_value(pool, :dropped, "dropped", [])

      {:ok,
       %{
         query_ref: instance.id,
         query_text: instance.query,
         question_type: instance.question_type,
         candidates: candidates
       }, length(dropped)}
    else
      {stage, {:error, reason}} ->
        {:error, stage_error(instance.id, stage, reason)}

      {stage, unexpected} ->
        {:error, stage_error(instance.id, stage, unexpected)}
    end
  end

  defp recall_payload(instance, top_k) do
    %{
      "query" => instance.query,
      "query_timestamp" => instance.query_timestamp,
      "max_tokens" => 50_000,
      "include" => %{"candidate_pool" => %{"top_k" => top_k}}
    }
  end

  defp stage_error(query_ref, _stage, {:generator_stage, stage, reason}) do
    %{stage: stage, query_ref: query_ref, reason: reason}
  end

  defp stage_error(query_ref, stage, reason) do
    %{stage: stage, query_ref: query_ref, reason: reason}
  end

  defp retain(ctx, memories) do
    case Foresight.retain(ctx, %{"items" => memories, "async" => false}) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:generator_stage, :retain, reason}}
    end
  end

  defp consolidate(ctx) do
    case Foresight.consolidate(ctx, %{"async" => false}, []) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:generator_stage, :consolidate, reason}}
    end
  end

  defp recall(ctx, payload) do
    case Foresight.recall(ctx, payload) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:generator_stage, :recall, reason}}
    end
  end

  defp stratified_sample(instances, per_type, seed) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})

    groups =
      instances
      |> Enum.group_by(& &1.question_type)
      |> Enum.sort_by(fn {type, _instances} -> to_string(type) end)

    target = min(per_type * length(groups), length(instances))

    {selected, remainder} =
      Enum.reduce(groups, {[], []}, fn {_type, group}, {selected, remainder} ->
        {take, rest} = group |> Enum.shuffle() |> Enum.split(per_type)
        {selected ++ take, remainder ++ rest}
      end)

    selected ++ (remainder |> Enum.shuffle() |> Enum.take(target - length(selected)))
  end

  defp query_bank_id(bank_id, query_ref) do
    suffix =
      :sha256
      |> :crypto.hash(to_string(query_ref))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "#{bank_id}-#{suffix}"
  end

  defp pool_value(pool, atom_key, string_key, default) do
    Map.get(pool, atom_key, Map.get(pool, string_key, default))
  end

  defp reverse_pools({:ok, pools, dropped_count}),
    do: {:ok, Enum.reverse(pools), dropped_count}

  defp reverse_pools(error), do: error
end
