defmodule Mix.Tasks.Foresight.Labeling.RepairReasons do
  use Mix.Task

  alias Foresight.Evals.Labeling.Judge
  alias Foresight.Evals.Labeling.LabelStore
  alias Foresight.Evals.Labeling.Pipeline
  alias Foresight.Evals.Labeling.RepoRuntime

  @shortdoc "Repair missing test-prefill reasons with GLM-5.2"

  @switches [
    input: :string,
    output: :string,
    concurrency: :integer,
    timeout_ms: :integer,
    confirm_paid: :boolean
  ]

  @defaults %{
    input: "tmp/labeling/judge-prefilled.json",
    output: "tmp/labeling/judge-prefilled-repaired.json",
    concurrency: 4,
    timeout_ms: 120_000,
    confirm_paid: false
  }

  @impl Mix.Task
  def run(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    opts = Map.merge(@defaults, Map.new(parsed))
    validate!(opts)
    artifact = opts.input |> File.read!() |> Jason.decode!()
    pairs = missing_reason_pairs(artifact)
    api_key = required_env!("OPENROUTER_API_KEY")
    print_estimate(pairs)

    unless opts.confirm_paid do
      Mix.raise("paid repair not confirmed; rerun with --confirm-paid after approval")
    end

    if File.exists?(opts.output), do: Mix.raise("output already exists: #{opts.output}")

    RepoRuntime.start!()
    {:ok, _apps} = Application.ensure_all_started(:req)

    result =
      Judge.label_all(pairs,
        llm: Foresight.LLMs.LlmCore,
        judge_model: "z-ai/glm-5.2",
        provider: "openai",
        provider_opts: [
          base_url: "https://openrouter.ai/api/v1",
          api_key: api_key,
          timeout: opts.timeout_ms
        ],
        concurrency: opts.concurrency,
        # Repairs backfill reasons onto rows already graded under v1. Pin the rubric so a
        # future change to the default cannot silently regrade them under a different one;
        # the persisted judge_model is derived from this, never asserted separately.
        rubric: "relevance-v1"
      )

    if result.errors != [] do
      Mix.raise("reason repair failed for #{length(result.errors)} of #{length(pairs)} pairs")
    end

    stored = LabelStore.write_all(result.labels)

    if stored.errors != [] do
      Mix.raise("failed to persist #{length(stored.errors)} repaired test labels")
    end

    repaired = Pipeline.prefill_test_artifact(artifact, result)

    unless missing_reason_pairs(repaired) == [] do
      Mix.raise("reason repair left test rows incomplete")
    end

    File.mkdir_p!(Path.dirname(opts.output))
    File.write!(opts.output, Jason.encode_to_iodata!(repaired, pretty: true))
    Mix.shell().info("wrote #{opts.output}; repaired #{length(pairs)} test reasons")
  end

  defp missing_reason_pairs(artifact) do
    missing_keys =
      artifact["pairs"]
      |> Enum.filter(fn row ->
        row["split"] == "test" and
          not (is_binary(row["judge_reason"]) and String.trim(row["judge_reason"]) != "")
      end)
      |> MapSet.new(&{&1["query_ref"], &1["memory_ref"]})

    artifact
    |> Pipeline.gold_judge_pairs()
    |> Enum.filter(&MapSet.member?(missing_keys, {&1.query_ref, &1.memory_ref}))
  end

  defp print_estimate(pairs) do
    input_tokens =
      pairs
      |> Enum.map(&(String.length(&1.query_text || "") + String.length(&1.content || "") + 240))
      |> Enum.sum()
      |> Kernel./(4)
      |> ceil()

    typical_cost = input_tokens / 1_000_000 * 0.798 + length(pairs) * 64 / 1_000_000 * 2.508
    maximum_cost = input_tokens / 1_000_000 * 0.798 + length(pairs) * 512 / 1_000_000 * 2.508

    Mix.shell().info("""
    paid reason-repair estimate
      calls: #{length(pairs)}
      estimated cost: $#{money(typical_cost)}
      bounded cost: $#{money(maximum_cost)}
      credential: OPENROUTER_API_KEY is set
    """)
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _other -> Mix.raise("#{name} is not set")
    end
  end

  defp money(amount), do: :erlang.float_to_binary(amount, decimals: 2)

  defp validate!(opts) do
    unless File.regular?(opts.input), do: Mix.raise("file not found: #{opts.input}")

    for key <- [:concurrency, :timeout_ms] do
      unless is_integer(opts[key]) and opts[key] > 0 do
        Mix.raise("--#{String.replace(to_string(key), "_", "-")} must be a positive integer")
      end
    end
  end
end
