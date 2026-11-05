defmodule Foresight.Evals.LongMemEvalRealMLEvalTest do
  @moduledoc """
  Authoritative LongMemEval recall-quality baseline on the REAL pipeline:
  Ecto + pgvector + sentence_transformers embeddings (bge-small-en-v1.5, MPS GPU)
  + sentence_transformers reranker (cross-encoder/ms-marco-MiniLM-L-6-v2, MPS GPU).

  This is NOT the FakeStorage lexical baseline. This produces the honest semantic number.

  ## GPU Backend Trap (READ THIS)

  Bumblebee/EXLA embedding is CPU-bound on Apple Silicon (no Metal in XLA). For GPU in
  dev use FORESIGHT_LOCAL_ML_BACKEND=sentence_transformers + python_executable pointing to
  a venv with torch+sentence-transformers that has MPS support
  (e.g. ~/.cache/foresight-ml-venv/bin/python). On deploy, GPU depends on the target
  server (DGX Spark=CUDA).

  DO NOT use Foresight.Embedders.Bumblebee here. It will silently fall back to CPU and
  grind for hours. The sentence_transformers worker auto-selects device=mps when
  force_cpu is false.

  Tagged `:eval` and `:ml` -- excluded from the default suite. Requires:
    - Fetched longmemeval_s split at priv/evals/data/longmemeval_s.json
    - PostgreSQL available (starts an isolated ephemeral instance via PostgresHarness)
    - Python venv at ~/.cache/foresight-ml-venv (torch + sentence-transformers, MPS)
    - ~15-30 minutes for stratified sample embedding on MPS GPU

  Protocol:
    - Per-instance banks (one bank per question, memories are the instance's haystack)
    - Stratified sampling with fixed seed (10 per question_type by default)
    - Scores: nDCG@10, MRR, Recall@5 via the harness (Runner + RankingMetrics)

  Environment overrides:
    FORESIGHT_LME_REAL_ML_PATH   path to longmemeval_s split
    FORESIGHT_LME_PER_TYPE       instances per question_type (default 10)
    FORESIGHT_LME_SEED           RNG seed for stratified sampling (default 42)
    FORESIGHT_ML_PYTHON          path to Python with sentence-transformers
  """
  use ExUnit.Case, async: false

  @moduletag :eval
  @moduletag :ml
  @moduletag timeout: 5_400_000

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.LongMemEval
  alias Foresight.Evals.Runner
  alias Foresight.TestSupport.FakeAsyncQueue
  alias Foresight.TestSupport.PostgresHarness

  require Logger

  @default_path "priv/evals/data/longmemeval_s.json"
  @default_per_type 10
  @default_seed 42

  @python_worker_name Module.concat(__MODULE__, PythonWorker)

  setup_all do
    path = System.get_env("FORESIGHT_LME_REAL_ML_PATH", @default_path)

    unless File.exists?(path) do
      IO.puts("\n[SKIP] #{path} not present -- run `mix foresight.evals.fetch longmemeval_s`")
      %{skip: "longmemeval_s data not available at #{path}"}
    else
      python_executable = resolve_python_executable!()

      # Verify MPS is available before proceeding
      verify_mps_device!(python_executable)

      harness = PostgresHarness.start!()
      repo_config = Application.get_env(:foresight, Foresight.Repo, [])
      original_backend = Application.get_env(:foresight, :backend)
      original_engine = Application.get_env(:foresight, :engine)
      original_ml = Application.get_env(:foresight, :ml)
      logger_level = Logger.level()

      Logger.configure(level: :warning)

      Application.put_env(
        :foresight,
        Foresight.Repo,
        Keyword.merge(repo_config,
          url: harness.url,
          pool_size: 10,
          timeout: 600_000,
          queue_target: 10_000,
          queue_interval: 30_000
        )
      )

      start_supervised!(Foresight.Repo)

      # Run migrations
      migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

      {:ok, _migrated, _apps} =
        Migrator.with_repo(Foresight.Repo, fn repo ->
          Migrator.run(repo, migrations_path, :up, all: true)
        end)

      # Start FakeAsyncQueue (used instead of Oban for synchronous retain)
      start_supervised!({FakeAsyncQueue, []})
      FakeAsyncQueue.reset!()

      # Start the Python ML worker (sentence_transformers on MPS)
      python_path = Path.join(:code.priv_dir(:foresight), "python")

      IO.puts("\n[LME-ML] Starting PythonLocalWorker (sentence_transformers, MPS)...")
      IO.puts("[LME-ML]   python_executable: #{python_executable}")
      IO.puts("[LME-ML]   python_path: #{python_path}")
      t0 = System.monotonic_time(:millisecond)

      start_supervised!(
        {Foresight.ML.PythonLocalWorker,
         name: @python_worker_name,
         python_executable: python_executable,
         python_path: python_path,
         model_id: "BAAI/bge-small-en-v1.5",
         reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
         force_cpu: false,
         trust_remote_code: false,
         preload_models: true}
      )

      t1 = System.monotonic_time(:millisecond)
      IO.puts("[LME-ML] PythonLocalWorker started + models preloaded in #{t1 - t0}ms")

      # ML config for the engine
      ml_config = [
        enabled: false,
        model_id: "BAAI/bge-small-en-v1.5",
        reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
        python_worker_name: @python_worker_name,
        python_executable: python_executable,
        python_path: python_path,
        force_cpu: false,
        trust_remote_code: false
      ]

      # Configure engine for real ML pipeline via sentence_transformers
      engine_config = [
        storage: Foresight.Storage.Ecto,
        repo: Foresight.Repo,
        embedder: Foresight.Embedders.SentenceTransformers,
        reranker: Foresight.Rerankers.SentenceTransformers,
        llm: Foresight.TestSupport.FakeLLM,
        queue: FakeAsyncQueue,
        oban_name: Foresight.Oban
      ]

      Application.put_env(:foresight, :backend, Foresight.Backend.Store)
      Application.put_env(:foresight, :engine, engine_config)
      Application.put_env(:foresight, :ml, ml_config)

      # Warm the embedding path via the Python worker
      IO.puts("[LME-ML] Warming embedding path (first model inference on MPS)...")
      t2 = System.monotonic_time(:millisecond)

      {:ok, warmup_emb} =
        Foresight.Embedders.SentenceTransformers.embed("warmup sentence for MPS",
          name: @python_worker_name
        )

      assert length(warmup_emb) == 384
      t3 = System.monotonic_time(:millisecond)
      IO.puts("[LME-ML] Warmup embedding done in #{t3 - t2}ms (dim=#{length(warmup_emb)})")

      # Verify the model ACTUALLY loaded on MPS -- do not assume. A silent CPU fallback
      # would produce equivalent numbers but mislabel provenance and grind for hours.
      {:ok, device} = Foresight.ML.PythonLocalWorker.device_info(name: @python_worker_name)
      embedder_device = device["embedder_device"] || "unknown"
      reranker_device = device["reranker_device"] || "unknown"

      IO.puts(
        "[LME-ML] embedder device: #{embedder_device} | reranker device: #{reranker_device}"
      )

      unless String.starts_with?(embedder_device, "mps") do
        flunk("""
        [LME-ML] BLOCKER: embedder loaded on #{inspect(embedder_device)}, not mps.
        Refusing to run -- a CPU fallback here would mislabel the baseline's provenance
        and take hours. Fix the sentence_transformers/MPS path before producing numbers.
        """)
      end

      IO.puts(
        "[LME-ML] Confirmed embedding device: #{embedder_device} (introspected, not assumed)"
      )

      on_exit(fn ->
        Logger.configure(level: logger_level)

        if original_backend do
          Application.put_env(:foresight, :backend, original_backend)
        else
          Application.delete_env(:foresight, :backend)
        end

        if original_engine do
          Application.put_env(:foresight, :engine, original_engine)
        else
          Application.delete_env(:foresight, :engine)
        end

        if original_ml do
          Application.put_env(:foresight, :ml, original_ml)
        else
          Application.delete_env(:foresight, :ml)
        end

        Application.put_env(:foresight, Foresight.Repo, repo_config)
        PostgresHarness.stop!(harness)
      end)

      {:ok,
       path: path,
       python_executable: python_executable,
       embedder_device: embedder_device,
       reranker_device: reranker_device}
    end
  end

  test "LongMemEval real-ML recall baseline (stratified, per-instance banks, sentence_transformers/MPS)",
       context do
    if context[:skip] do
      IO.puts("\n[skip] #{context[:skip]}")
      assert true
    else
      path = context[:path]
      embedder_device = context[:embedder_device] || "unknown"
      reranker_device = context[:reranker_device] || "unknown"
      per_type = env_integer("FORESIGHT_LME_PER_TYPE", @default_per_type)
      seed = env_integer("FORESIGHT_LME_SEED", @default_seed)

      # Load full dataset
      IO.puts("\n[LME-ML] Loading #{path}...")
      t_load_0 = System.monotonic_time(:millisecond)
      all_instances = LongMemEval.load!(path)
      t_load_1 = System.monotonic_time(:millisecond)

      IO.puts("[LME-ML] Loaded #{length(all_instances)} instances in #{t_load_1 - t_load_0}ms")

      # Stratified sampling: per_type instances per question_type, fixed seed
      instances = stratified_sample(all_instances, per_type, seed)
      type_counts = instances |> Enum.frequencies_by(& &1.question_type)

      IO.puts("[LME-ML] Stratified sample: #{length(instances)} instances (seed=#{seed})")

      for {type, count} <- Enum.sort(type_counts) do
        IO.puts("  #{type}: #{count}")
      end

      # Total memories to embed (for logging)
      total_memories = instances |> Enum.map(&length(&1.memories)) |> Enum.sum()
      IO.puts("[LME-ML] Total sessions to embed across all instances: #{total_memories}")

      # Per-instance eval: retain each instance's haystack into its own bank, recall, score
      recall_fun = fn inst ->
        bank_id = "lme-ml-#{inst.id}"
        ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

        # Retain this instance's memories (synchronous, includes embedding)
        memories = inst.memories

        case retain_with_batching(ctx, memories) do
          {:ok, _retained_count} ->
            # Verify at least one memory has an embedding
            verify_embedding!(bank_id, inst.id)

            # Recall
            case Foresight.recall(ctx, %{
                   "query" => inst.query,
                   "query_timestamp" => inst.query_timestamp,
                   "max_tokens" => 50_000
                 }) do
              {:ok, %{"results" => results}} ->
                results

              {:error, error} ->
                IO.puts("[LME-ML] WARN: recall failed for #{inst.id}: #{inspect(error)}")

                []
            end

          {:error, reason} ->
            IO.puts("[LME-ML] WARN: retain failed for #{inst.id}: #{inspect(reason)}")

            []
        end
      end

      # Run the harness
      IO.puts("\n[LME-ML] Running eval (this will take several minutes)...")
      t_eval_0 = System.monotonic_time(:millisecond)
      report = Runner.run(instances, recall_fun, k: 10, recall_k: 5)
      t_eval_1 = System.monotonic_time(:millisecond)

      # Output results
      IO.puts("\n" <> String.duplicate("=", 80))

      IO.puts(
        "=== LongMemEval REAL-ML Recall Baseline (#{length(instances)} queries, seed=#{seed}) ==="
      )

      IO.puts(String.duplicate("=", 80))
      IO.puts("Backend: Foresight.Storage.Ecto + pgvector")

      IO.puts(
        "Embedder: Foresight.Embedders.SentenceTransformers (BAAI/bge-small-en-v1.5, dim=384, device=#{embedder_device})"
      )

      IO.puts(
        "Reranker: Foresight.Rerankers.SentenceTransformers (cross-encoder/ms-marco-MiniLM-L-6-v2, device=#{reranker_device})"
      )

      IO.puts("Protocol: per-instance banks (one bank per question, instance haystack)")
      IO.puts("Sample: stratified #{per_type}/type, seed=#{seed}")
      IO.puts("Total sessions embedded: #{total_memories}")
      IO.puts("Wall time: #{t_eval_1 - t_eval_0}ms")
      IO.puts("")
      IO.puts(Runner.format_report(report) <> "\n")
      IO.puts(String.duplicate("=", 80))

      # Write machine-readable results to a tmp file for the report script
      results_path = Path.join(System.tmp_dir!(), "foresight_lme_real_ml_results.json")

      results_json = %{
        "overall" => serialize_metrics(report.overall),
        "by_type" =>
          Map.new(report.by_type, fn {type, metrics} -> {type, serialize_metrics(metrics)} end),
        "config" => %{
          "path" => path,
          "per_type" => per_type,
          "seed" => seed,
          "total_instances" => length(instances),
          "total_memories" => total_memories,
          "embedder" => "BAAI/bge-small-en-v1.5 (sentence_transformers)",
          "reranker" => "cross-encoder/ms-marco-MiniLM-L-6-v2 (sentence_transformers)",
          "embedder_device" => embedder_device,
          "reranker_device" => reranker_device,
          "wall_time_ms" => t_eval_1 - t_eval_0
        },
        "type_counts" => type_counts
      }

      File.write!(results_path, Jason.encode!(results_json, pretty: true))
      IO.puts("\n[LME-ML] Results written to #{results_path}")

      # Sanity assertions (not quality gates, just structural)
      assert report.overall.n == length(instances)
      assert report.overall.ndcg >= 0.0
      assert report.overall.mrr >= 0.0
      assert report.overall.recall >= 0.0
    end
  end

  # --- Helpers ---

  defp stratified_sample(instances, per_type, seed) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})

    instances
    |> Enum.group_by(& &1.question_type)
    |> Enum.sort_by(fn {type, _} -> type end)
    |> Enum.flat_map(fn {_type, group} ->
      group
      |> Enum.shuffle()
      |> Enum.take(per_type)
    end)
  end

  defp retain_with_batching(ctx, memories) do
    # Retain in chunks of 5 -- each chunk requires embedding + entity extraction,
    # and LongMemEval sessions can be long (many turns per session).
    batch_size = 5

    results =
      memories
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, acc} ->
        case Foresight.retain(ctx, %{"items" => chunk, "async" => false}) do
          {:ok, %{"items_count" => count}} ->
            {:cont, {:ok, acc + count}}

          {:ok, %{"success" => true, "items_count" => count}} ->
            {:cont, {:ok, acc + count}}

          {:ok, response} ->
            count = Map.get(response, "items_count", length(chunk))
            {:cont, {:ok, acc + count}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    results
  end

  defp verify_embedding!(bank_id, instance_id) do
    case SQL.query(
           Foresight.Repo,
           "SELECT COUNT(*) FROM memory_units WHERE bank_id = $1 AND embedding_384 IS NOT NULL",
           [bank_id]
         ) do
      {:ok, %{rows: [[count]]}} when count > 0 ->
        :ok

      {:ok, %{rows: [[0]]}} ->
        IO.puts(
          "[LME-ML] WARNING: Instance #{instance_id}: 0 embedded memories in bank #{bank_id}"
        )

        :ok

      {:error, error} ->
        IO.puts(
          "[LME-ML] WARNING: Instance #{instance_id}: embedding check failed: #{inspect(error)}"
        )

        :ok
    end
  end

  defp serialize_metrics(metrics) do
    %{
      "n" => metrics.n,
      "ndcg" => Float.round(metrics.ndcg, 4),
      "mrr" => Float.round(metrics.mrr, 4),
      "recall" => Float.round(metrics.recall, 4)
    }
  end

  defp env_integer(key, default) do
    case System.get_env(key) do
      nil -> default
      val -> String.to_integer(val)
    end
  end

  defp resolve_python_executable! do
    env_python = System.get_env("FORESIGHT_ML_PYTHON")
    venv_python = Path.expand("~/.cache/foresight-ml-venv/bin/python")
    default_python = System.find_executable("python3") || "python3"

    cond do
      is_binary(env_python) and env_python != "" and File.exists?(env_python) ->
        env_python

      File.exists?(venv_python) ->
        venv_python

      File.exists?(default_python) ->
        default_python

      true ->
        flunk("""
        [LME-ML] No Python executable with sentence-transformers found.

        Set FORESIGHT_ML_PYTHON or install the venv at ~/.cache/foresight-ml-venv:
          python3 -m venv ~/.cache/foresight-ml-venv
          ~/.cache/foresight-ml-venv/bin/pip install torch sentence-transformers
        """)
    end
  end

  defp verify_mps_device!(python_executable) do
    check_script =
      "import torch, json, sys; info = {\"mps_available\": torch.backends.mps.is_available(), \"torch_version\": torch.__version__}; print(json.dumps(info))"

    case System.cmd(python_executable, ["-c", check_script], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(String.trim(output)) do
          {:ok, %{"mps_available" => true, "torch_version" => version}} ->
            IO.puts("[LME-ML] MPS device available (torch #{version})")
            :ok

          {:ok, %{"mps_available" => false}} ->
            flunk("""
            [LME-ML] BLOCKER: MPS is NOT available on this machine.
            The embedding would fall back to CPU, which is unacceptable for this eval.
            torch.backends.mps.is_available() returned False.
            """)

          {:error, reason} ->
            flunk("[LME-ML] Failed to parse MPS check output: #{inspect(reason)}")
        end

      {output, code} ->
        flunk("""
        [LME-ML] Python MPS check failed (exit #{code}):
        #{output}
        """)
    end
  end
end
