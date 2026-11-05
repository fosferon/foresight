defmodule Mix.Tasks.Foresight.Labeling.Generate do
  use Mix.Task

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.Labeling.Generator
  alias Foresight.Evals.LongMemEval
  alias Foresight.Evals.ProfessionalLane
  alias Foresight.Profiles.FullMLAuthority

  @shortdoc "Generate a relevance-labeling artifact for human grading from an evaluation corpus"

  @switches [
    dataset: :string,
    path: :string,
    output: :string,
    pool_output: :string,
    bank_id: :string,
    per_type: :integer,
    seed: :integer,
    top_k: :integer,
    per_query_cap: :integer,
    target_pairs: :integer,
    calibration_ratio: :float,
    concurrency: :integer,
    reuse_banks: :boolean,
    force: :boolean
  ]

  @defaults %{
    dataset: "longmemeval",
    path: "priv/evals/data/longmemeval_s.json",
    output: "tmp/labeling/gold.json",
    pool_output: "tmp/labeling/pools.json",
    bank_id: "d2-longmemeval-s",
    per_type: 5,
    seed: 42,
    top_k: 20,
    per_query_cap: 10,
    target_pairs: 150,
    calibration_ratio: 0.267,
    concurrency: 6,
    reuse_banks: false,
    force: false
  }

  @impl Mix.Task
  def run(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    opts = Map.merge(@defaults, Map.new(parsed))
    validate_opts!(opts)
    ensure_file!(opts.path)
    ensure_output_available!(opts.output, opts.force)
    ensure_output_available!(opts.pool_output, opts.force)
    start_runtime!()
    ensure_label_bank!(opts.bank_id, opts.dataset)

    instances = load_instances!(opts.dataset, opts.path)

    Mix.shell().info(
      "loaded #{length(instances)} #{opts.dataset} instances; sampling #{opts.per_type}/type"
    )

    generator_opts = [
      bank_id: opts.bank_id,
      per_type: opts.per_type,
      seed: opts.seed,
      target_pairs: opts.target_pairs,
      calibration_ratio: opts.calibration_ratio,
      per_query_cap: opts.per_query_cap,
      top_k: opts.top_k,
      concurrency: opts.concurrency
    ]

    generator_opts =
      if opts.reuse_banks do
        generator_opts ++
          [prepare: &noop_prepare/1, retain: &noop_retain/2, consolidate: &noop_consolidate/1]
      else
        Keyword.put(generator_opts, :prepare, &reset_query_bank/1)
      end

    case Generator.generate(instances, generator_opts) do
      {:ok, result} ->
        write_artifact!(result, opts)

      {:error, error} ->
        Mix.raise("labeling generation failed: #{inspect(error, pretty: true)}")
    end
  end

  defp start_runtime! do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:ecto_sql)
    {:ok, _apps} = Application.ensure_all_started(:erlport)

    env =
      System.get_env()
      |> Map.put("FORESIGHT_FILE_INGESTION", "0")
      |> Map.put("FORESIGHT_LOCAL_ML_BACKEND", "sentence_transformers")
      |> Map.put_new(
        "FORESIGHT_ML_PYTHON",
        Path.expand("~/.cache/foresight-ml-venv/bin/python")
      )

    profile = FullMLAuthority.build(env)
    ensure_python!(get_in(profile.opts, [:ml, :python_executable]))

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(
      :foresight,
      :engine,
      profile.engine_config
      |> Map.put(:llm, Foresight.LLMs.Noop)
      |> Map.put(:retain_extraction_mode, nil)
      |> Map.put(:retain_extraction_provider_opts, nil)
      |> Map.put(:consolidation_provider_opts, nil)
    )

    Application.put_env(:foresight, :ml, profile.resolved_config.ml)

    repo_opts =
      profile.repo_start_opts
      |> Keyword.put_new(:types, Foresight.PostgrexTypes)
      |> Keyword.put(:timeout, 600_000)
      |> Keyword.put(:queue_target, 10_000)
      |> Keyword.put(:queue_interval, 30_000)
      |> Keyword.put(:log, false)

    Application.put_env(:foresight, Foresight.Repo, repo_opts)

    start_once(Foresight.Repo, fn -> Foresight.Repo.start_link(repo_opts) end)
    migrate!()

    ml_opts =
      profile.opts
      |> Keyword.fetch!(:ml)
      |> Keyword.put(:name, Foresight.ML.PythonLocalWorker)

    start_once(Foresight.ML.PythonLocalWorker, fn ->
      Foresight.ML.PythonLocalWorker.start_link(ml_opts)
    end)

    verify_ml_device!()
  end

  defp migrate! do
    migrations_path = Application.app_dir(:foresight, "priv/repo/migrations")

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)
  end

  defp reset_query_bank(ctx) do
    case Foresight.delete_bank(ctx, ctx.bank) do
      {:ok, _result} -> {:ok, %{}}
      {:error, %Foresight.Error{reason: :not_found}} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp noop_prepare(_ctx), do: {:ok, %{}}
  defp noop_retain(_ctx, _memories), do: {:ok, %{}}
  defp noop_consolidate(_ctx), do: {:ok, %{}}

  defp ensure_label_bank!(bank_id, dataset) do
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    case Foresight.put_bank(ctx, bank_id, %{
           "name" => "#{dataset} relevance labels",
           "mission" => "Hold relevance labels for learned per-bank recall fusion."
         }) do
      {:ok, _bank} -> :ok
      {:error, reason} -> Mix.raise("failed to prepare label bank: #{inspect(reason)}")
    end
  end

  defp write_artifact!(result, opts) do
    pair_count = length(result.artifact["pairs"])

    if pair_count != opts.target_pairs do
      Mix.raise(
        "candidate pools yielded #{pair_count} pairs, expected #{opts.target_pairs}; artifact not written"
      )
    end

    calibration_count =
      Enum.count(result.artifact["pairs"], &(&1["split"] == "calibration"))

    test_count = pair_count - calibration_count
    File.mkdir_p!(Path.dirname(opts.output))
    File.write!(opts.output, Jason.encode_to_iodata!(result.artifact, pretty: true))
    File.mkdir_p!(Path.dirname(opts.pool_output))

    File.write!(
      opts.pool_output,
      Jason.encode_to_iodata!(
        %{
          "version" => 1,
          "bank_id" => opts.bank_id,
          "query_pools" => result.query_pools
        },
        pretty: true
      )
    )

    Mix.shell().info("""
    wrote #{opts.output}
    wrote #{opts.pool_output}
      pairs: #{pair_count}
      calibration/test: #{calibration_count}/#{test_count}
      queries: #{length(result.query_pools)}
      dropped candidates without eval_id: #{result.dropped_count}
    """)
  end

  defp verify_ml_device! do
    {:ok, device} = Foresight.ML.PythonLocalWorker.device_info()
    embedder_device = device["embedder_device"] || "unknown"

    unless String.starts_with?(embedder_device, "mps") do
      Mix.raise("embedding model loaded on #{inspect(embedder_device)}, expected MPS")
    end

    Mix.shell().info("sentence-transformers ready on #{embedder_device}")
  end

  defp start_once(name, start_fun) do
    if Process.whereis(name) == nil do
      case start_fun.() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Mix.raise("failed to start #{inspect(name)}: #{inspect(reason)}")
      end
    end
  end

  defp ensure_python!(path) when is_binary(path) do
    unless File.exists?(path) do
      Mix.raise("FORESIGHT_ML_PYTHON does not exist: #{path}")
    end
  end

  defp ensure_python!(_path), do: Mix.raise("FORESIGHT_ML_PYTHON is required")

  defp ensure_file!(path) do
    unless File.exists?(path) do
      Mix.raise("LongMemEval-S corpus not found: #{path}")
    end
  end

  defp load_instances!("longmemeval", path), do: LongMemEval.load!(path)
  defp load_instances!("professional", path), do: ProfessionalLane.load!(path)

  @doc false
  def ensure_output_available!(path, force?) do
    if File.exists?(path) and not force? do
      Mix.raise("output already exists: #{path}; pass --force to overwrite it")
    end
  end

  defp validate_opts!(opts) do
    unless opts.dataset in ["longmemeval", "professional"] do
      Mix.raise("--dataset must be longmemeval or professional")
    end

    unless is_float(opts.calibration_ratio) and opts.calibration_ratio > 0.0 and
             opts.calibration_ratio < 1.0 do
      Mix.raise("--calibration-ratio must be between 0 and 1")
    end

    if Path.expand(opts.output) == Path.expand(opts.pool_output) do
      Mix.raise("--output and --pool-output must be different paths")
    end

    for key <- [:per_type, :seed, :top_k, :per_query_cap, :target_pairs, :concurrency] do
      unless is_integer(opts[key]) and opts[key] > 0 do
        Mix.raise("--#{String.replace(to_string(key), "_", "-")} must be a positive integer")
      end
    end
  end
end
