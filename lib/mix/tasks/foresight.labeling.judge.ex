defmodule Mix.Tasks.Foresight.Labeling.Judge do
  use Mix.Task

  alias Foresight.Evals.Labeling.Judge
  alias Foresight.Evals.Labeling.LabelStore
  alias Foresight.Evals.Labeling.Pipeline
  alias Foresight.Evals.Labeling.RepoRuntime

  @shortdoc "Run a relevance-labeling judge pass (--route dgx is local and free)"

  @switches [
    gold: :string,
    pools: :string,
    output: :string,
    errors_output: :string,
    route: :string,
    concurrency: :integer,
    timeout_ms: :integer,
    retries: :integer,
    splits: :string,
    confirm_paid: :boolean
  ]

  @defaults %{
    gold: "tmp/labeling/gold.json",
    pools: "tmp/labeling/pools.json",
    output: "tmp/labeling/judge-prefilled.json",
    errors_output: "tmp/labeling/judge-errors.json",
    route: "direct",
    concurrency: 4,
    timeout_ms: 120_000,
    retries: 2,
    splits: "calibration,test,train",
    confirm_paid: false
  }

  @prompt_overhead_chars 1_300

  @impl Mix.Task
  def run(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    opts = Map.merge(@defaults, Map.new(parsed))
    validate!(opts)

    gold = read_json!(opts.gold)
    pools = read_json!(opts.pools)
    ensure_matching_banks!(gold, pools)

    splits = selected_splits!(opts.splits)
    pairs = Pipeline.judge_pairs(pools, gold, splits)
    route = route!(opts.route)
    print_estimate(pairs, route, opts.retries + 1)

    api_key =
      if route.paid? do
        key_name = configured_key_name!(route)
        Mix.shell().info("  credential: #{key_name} is set")

        unless opts.confirm_paid do
          Mix.raise("paid run not confirmed; rerun with --confirm-paid after approval")
        end

        System.fetch_env!(key_name)
      else
        # Local OpenAI-compatible servers ignore the key but the client requires a binary.
        "local"
      end

    ensure_output_available!(opts.output)
    ensure_output_available!(opts.errors_output)
    RepoRuntime.start!()
    {:ok, _apps} = Application.ensure_all_started(:req)

    result =
      Judge.label_all(pairs,
        llm: Foresight.LLMs.LlmCore,
        judge_model: route.model,
        provider: "openai",
        provider_opts: [
          base_url: route.base_url,
          api_key: api_key,
          timeout: opts.timeout_ms
        ],
        concurrency: opts.concurrency,
        max_attempts: opts.retries + 1,
        retry_sleep_ms: 1_000
      )

    if result.errors != [] do
      write_json!(opts.errors_output, %{
        "version" => 1,
        "route" => opts.route,
        "judge_model" => route.model,
        "errors" => Enum.map(result.errors, &serializable_error/1)
      })

      Mix.raise(
        "judge failed for #{length(result.errors)} of #{length(pairs)} pairs; " <>
          "no labels persisted, see #{opts.errors_output}"
      )
    end

    stored = LabelStore.write_all(result.labels)

    if stored.errors != [] do
      Mix.raise("failed to persist #{length(stored.errors)} judge labels")
    end

    # Read the recorded provenance back off a real label rather than recomputing it, so
    # what is reported is what was persisted.
    label_model =
      case result.labels do
        [%{judge_model: model} | _rest] -> model
        [] -> "#{route.model}@#{Judge.rubric_version()}"
      end

    prefilled = Pipeline.prefill_test_artifact(gold, result)
    write_json!(opts.output, prefilled)

    calibration = Enum.count(result.labels, &(&1.split == :calibration))
    test = Enum.count(result.labels, &(&1.split == :test))
    train = Enum.count(result.labels, &(&1.split == :train))

    Mix.shell().info("""
    wrote #{opts.output}
      labels persisted: #{stored.written}
      calibration/test/train: #{calibration}/#{test}/#{train}
      judge: #{label_model} via #{opts.route}
    """)
  end

  defp route!("direct") do
    %{
      base_url: "https://api.z.ai/api/paas/v4",
      model: "glm-5.2",
      paid?: true,
      input_per_million: 1.40,
      output_per_million: 4.40,
      key_names: ["ZAI_API_KEY", "FORESIGHT_LLM_API_KEY"]
    }
  end

  defp route!("openrouter") do
    %{
      base_url: "https://openrouter.ai/api/v1",
      model: "z-ai/glm-5.2",
      paid?: true,
      input_per_million: 0.798,
      output_per_million: 2.508,
      key_names: ["OPENROUTER_API_KEY", "FORESIGHT_LLM_API_KEY"]
    }
  end

  # Local Ollama on the DGX. Free, so no --confirm-paid gate and no credential.
  # The kappa gate is what validates a judge, not its price: any model that clears
  # quadratic kappa against the human/independent labels is an admissible judge.
  defp route!("dgx") do
    %{
      base_url: System.get_env("FORESIGHT_DGX_BASE_URL", "http://localhost:11434/v1"),
      model: System.get_env("FORESIGHT_DGX_JUDGE_MODEL", "gpt-oss:120b"),
      paid?: false,
      input_per_million: 0.0,
      output_per_million: 0.0,
      key_names: []
    }
  end

  defp route!(route) do
    Mix.raise("unsupported --route #{inspect(route)}; expected direct, openrouter, or dgx")
  end

  defp print_estimate(pairs, route, max_attempts) do
    input_tokens =
      pairs
      |> Enum.map(
        &(String.length(&1.query_text || "") + String.length(&1.content || "") +
            @prompt_overhead_chars)
      )
      |> Enum.sum()
      |> Kernel./(4)
      |> ceil()

    typical_output_tokens = length(pairs) * 64
    maximum_output_tokens = length(pairs) * 512

    if route.paid? do
      typical_cost =
        token_cost(input_tokens, typical_output_tokens, route)

      maximum_cost =
        token_cost(input_tokens * max_attempts, maximum_output_tokens * max_attempts, route)

      Mix.shell().info("""
      paid judge estimate
        calls: #{length(pairs)} (up to #{length(pairs) * max_attempts} with retries)
        estimated input tokens: #{input_tokens}
        estimated cost (64 output tokens/call): $#{money(typical_cost)}
        bounded cost (512 output tokens/call): $#{money(maximum_cost)}
      """)
    else
      Mix.shell().info("""
      local judge run (no spend)
        calls: #{length(pairs)} (up to #{length(pairs) * max_attempts} with retries)
        estimated input tokens: #{input_tokens}
        model: #{route.model} at #{route.base_url}
      """)
    end
  end

  defp token_cost(input_tokens, output_tokens, route) do
    input_tokens / 1_000_000 * route.input_per_million +
      output_tokens / 1_000_000 * route.output_per_million
  end

  defp money(amount), do: :erlang.float_to_binary(amount, decimals: 2)

  defp configured_key_name!(route) do
    case Enum.find_value(route.key_names, &present_env/1) do
      {name, _value} ->
        name

      nil ->
        Mix.raise("missing API key; set one of #{Enum.join(route.key_names, ", ")}")
    end
  end

  defp present_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {name, value}
      _other -> nil
    end
  end

  defp ensure_matching_banks!(gold, pools) do
    unless gold["bank_id"] == pools["bank_id"] do
      Mix.raise("gold and pool artifacts have different bank ids")
    end
  end

  defp selected_splits!(value) when is_binary(value) do
    allowed = %{"calibration" => :calibration, "test" => :test, "train" => :train}

    splits =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    if splits == [] or Enum.any?(splits, &(&1 == "" or not Map.has_key?(allowed, &1))) do
      Mix.raise("--splits must be a comma-separated subset of calibration,test,train")
    end

    splits
    |> Enum.map(&Map.fetch!(allowed, &1))
    |> Enum.uniq()
  end

  defp selected_splits!(_value) do
    Mix.raise("--splits must be a comma-separated subset of calibration,test,train")
  end

  defp ensure_output_available!(path) do
    if File.exists?(path), do: Mix.raise("output already exists: #{path}")
  end

  defp read_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(data, pretty: true))
  end

  defp serializable_error(error) do
    Map.update(error, :reason, nil, &inspect/1)
  end

  defp validate!(opts) do
    for key <- [:concurrency, :timeout_ms] do
      unless is_integer(opts[key]) and opts[key] > 0 do
        Mix.raise("--#{String.replace(to_string(key), "_", "-")} must be a positive integer")
      end
    end

    unless is_integer(opts.retries) and opts.retries >= 0 do
      Mix.raise("--retries must be a non-negative integer")
    end

    for key <- [:gold, :pools] do
      unless File.regular?(opts[key]), do: Mix.raise("file not found: #{opts[key]}")
    end
  end
end
