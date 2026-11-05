defmodule Foresight.Evals.LongMemEvalReflectJudgeEvalTest do
  @moduledoc """
  Reflect answer-quality lane.

  The question this lane exists to answer: does the **agentic reflect loop** + **real consolidated observations** lift the cross-session
  aggregation (`multi-session`) and `temporal-reasoning` classes above the naive
  fixed-reader floor — for the RIGHT reasons (reflect/consolidation doing the work,
  not retrieval heuristics)?

  ## Design — matched pair, reader is the ONLY variable

  Per sampled instance, on ONE retained+consolidated bank state:

    1. retain the haystack (real Ecto + pgvector + sentence-transformers/MPS embeddings)
    2. consolidate synchronously (`async: false`) so `search_observations` has real,
       merged, embedded observations to find (replaces the earlier zero-vector stub)
    3. produce TWO answers over the SAME bank:
         A. FIXED READER  — Foresight.recall -> top-8 context -> plain completion
            (identical to longmemeval_answer_judge_eval_test; the baseline reader)
         B. REFLECT       — Foresight.reflect (the agentic tool-calling loop)
    4. an INDEPENDENT judge model scores each answer against the gold reference
       (CORRECT / INCORRECT; abstention instances scored on correct declination)

  Because retrieval and the judge are held constant and both readers see the same
  bank, any A→B delta is attributable to the reader — i.e. to reflect + consolidation.

  HONESTY GUARDRAILS (the honest-numbers mandate):
    * We record, per instance, whether reflect actually took the AGENTIC path
      (trace.mode == "agentic") or fell back to the fixed structured pipeline —
      because a local model that cannot tool-call would silently make B == the
      fallback, not the agentic loop. The report prints the agentic ratio.
    * We record observations_written by consolidation, so a claim that
      "consolidation did the work" is backed by non-zero observations.
    * Corpus is longmemeval_oracle (evidence-only, "reflect dev"): retrieval is
      near-trivial by construction, which ISOLATES the reader/aggregation step.
      This is NOT the _s retrieval-at-scale corpus.

  ## Third arm — Foresight vs Hindsight (foresight_bench)

  When `FORESIGHT_LME_HINDSIGHT_BASE_URL` points at a LIVE Hindsight authority, each
  instance runs a THIRD arm: the SAME sessions are retained → consolidated → reflected
  on Hindsight over its HTTP API (`Foresight.Evals.HindsightBench`) and scored by the
  SAME judge. The report then prints Foresight-reflect vs Hindsight-reflect per
  question_type with a paired McNemar test. This is the matched-reader scoreboard —
  and it is only FAIR if that authority runs reflect AND consolidation on the same
  reader as Foresight (gpt-oss:20b); start it with
  `scripts/start-hindsight-fixture-authority.sh` under `HINDSIGHT_USE_LMSTUDIO=1` +
  the DGX base url (the script now exports the REFLECT/CONSOLIDATION LLM families, not
  only the primary). Absent the env, the arm is OFF and `hindsight_correct` is nil
  (never conflated with a scored 0).

  ## Statistics

  A single accuracy at n≈30 has a ±0.08 standard error, so a bare "reflect 0.70 vs
  fixed 0.70, delta 0.000" is not evidence of equality — it is two point estimates
  that happen to coincide. The report therefore prints, via `Foresight.Evals.Stats`:

    * a 95% **Wilson** score interval per arm (so the width of the uncertainty is
      visible and boundary-safe);
    * the **paired** reflect−fixed comparison as an exact **McNemar** p-value over
      the discordant instances — the correct test because both arms answer the SAME
      questions on the SAME bank, so only instances where they DISAGREE carry signal.

  A single run cannot establish an A/A noise floor (how much the score moves from LLM
  nondeterminism alone). To claim a delta is real, run the eval ≥3 times at a fixed
  seed and feed the per-run accuracies to `Stats.replicate_summary/1`; a delta inside
  that noise band is not attributable to a code change.

  ## GPU / LLM setup — same as the answer-judge lane

  Env:
    FORESIGHT_ML_PYTHON           venv python with torch+sentence-transformers (MPS)
    FORESIGHT_LLM_BASE_URL        default http://127.0.0.1:1234/v1
    FORESIGHT_LME_ANSWER_MODEL    reader/reflect model (default instruct model below)
    FORESIGHT_LME_JUDGE_MODEL     judge model (default instruct model below)
    FORESIGHT_LME_PER_TYPE        instances per question_type (default 3)
    FORESIGHT_LME_SEED            stratified sampling seed (default 42)
    FORESIGHT_LME_REFLECT_ITERS   agentic loop max iterations (default 4)
    FORESIGHT_LME_HINDSIGHT_BASE_URL  live Hindsight authority (arm OFF if unset)
    FORESIGHT_LME_HINDSIGHT_API_KEY   bearer for the Hindsight authority
                                      (default sk-foresight-fixtures-dev)
  """
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.DegradationWatch
  alias Foresight.Evals.HindsightBench
  alias Foresight.Evals.LongMemEval
  alias Foresight.Evals.Stats
  alias Foresight.TestSupport.FakeAsyncQueue
  alias Foresight.TestSupport.PostgresHarness

  require Logger

  @moduletag :eval
  @moduletag :ml
  @moduletag :llm
  # 5h ceiling: the matched Foresight-vs-Hindsight run adds a full Hindsight
  # retain+consolidate+reflect per instance on a slow reasoning reader (gpt-oss:20b),
  # well beyond the 2h the Foresight-only lane needed.
  @moduletag timeout: 18_000_000

  @default_path "priv/evals/data/longmemeval_oracle.json"
  @default_per_type 3
  @default_seed 42
  # Direct-answering instruct model (not a "thinking" model): thinking models emit
  # reasoning tokens first and leave `content` empty under a small max_tokens budget,
  # silently zeroing both the answer and the judge verdict.
  @default_answer_model "qwen3-vl-8b-instruct-c_abliterated-v3-mlx"
  @default_judge_model "qwen3-vl-8b-instruct-c_abliterated-v3-mlx"

  @python_worker_name Module.concat(__MODULE__, PythonWorker)

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    path = System.get_env("FORESIGHT_LME_REFLECT_PATH", @default_path)
    base_url = System.get_env("FORESIGHT_LLM_BASE_URL", "http://127.0.0.1:1234/v1")

    cond do
      not File.exists?(path) ->
        %{skip: "longmemeval data not available at #{path}"}

      resolve_python_executable() == nil ->
        %{skip: "no sentence-transformers venv (set FORESIGHT_ML_PYTHON)"}

      not llm_reachable?(base_url) ->
        %{skip: "no LLM endpoint reachable at #{base_url} (start LMStudio)"}

      true ->
        python_executable = resolve_python_executable()
        verify_mps_device!(python_executable)

        harness = PostgresHarness.start!()
        repo_config = Application.get_env(:foresight, Foresight.Repo, [])

        original = %{
          backend: Application.get_env(:foresight, :backend),
          engine: Application.get_env(:foresight, :engine),
          ml: Application.get_env(:foresight, :ml)
        }

        logger_level = Logger.level()
        Logger.configure(level: :warning)

        Application.put_env(
          :foresight,
          Foresight.Repo,
          Keyword.merge(repo_config, url: harness.url, pool_size: 40, timeout: 600_000)
        )

        start_supervised!(Foresight.Repo)

        migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

        {:ok, _migrated, _apps} =
          Migrator.with_repo(Foresight.Repo, fn repo ->
            Migrator.run(repo, migrations_path, :up, all: true)
          end)

        start_supervised!({FakeAsyncQueue, []})
        FakeAsyncQueue.reset!()

        python_path = Path.join(:code.priv_dir(:foresight), "python")
        answer_model = System.get_env("FORESIGHT_LME_ANSWER_MODEL", @default_answer_model)

        start_supervised!(
          {Foresight.ML.PythonLocalWorker,
           name: @python_worker_name,
           python_executable: python_executable,
           python_path: python_path,
           model_id: "BAAI/bge-small-en-v1.5",
           reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
           force_cpu: false,
           preload_models: true}
        )

        ml_config = [
          enabled: false,
          model_id: "BAAI/bge-small-en-v1.5",
          reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
          python_worker_name: @python_worker_name,
          python_executable: python_executable,
          python_path: python_path,
          force_cpu: false
        ]

        engine_config = %{
          storage: Foresight.Storage.Ecto,
          repo: Foresight.Repo,
          embedder: Foresight.Embedders.SentenceTransformers,
          reranker: Foresight.Rerankers.SentenceTransformers,
          llm: Foresight.LLMs.LlmCore,
          provider: "openai",
          provider_opts: [
            base_url: base_url,
            api_key: System.get_env("FORESIGHT_LLM_API_KEY", "lm-studio"),
            model: answer_model,
            # Overridable because the 2026-08-14 run timed out against a contended DGX and
            # silently degraded every arm. Waiting longer is strictly better than scoring
            # a broken run.
            timeout: env_integer("FORESIGHT_LME_LLM_TIMEOUT_MS", 180_000)
          ],
          queue: FakeAsyncQueue,
          oban_name: Foresight.Oban,
          # Retain-time atomic-fact extraction. Off by default so the
          # eval's baseline is the historical whole-session-blob behaviour; set
          # FORESIGHT_LME_RETAIN_EXTRACTION=concise to atomize each session into
          # discrete facts (via the same LlmCore endpoint) and measure whether it
          # moves multi-session/temporal off 0.0.
          retain_extraction_mode: System.get_env("FORESIGHT_LME_RETAIN_EXTRACTION"),
          # Extraction needs clean structured-JSON output; not every reader/
          # tool-calling model gives that. FORESIGHT_LME_EXTRACT_MODEL points
          # extraction at a JSON-reliable model (e.g. gemma3:12b) while the
          # reader/judge/reflect model stays whatever ANSWER/JUDGE selects.
          retain_extraction_provider_opts: extraction_provider_opts(base_url),
          # Consolidation is also structured-JSON output (creates/updates/deletes);
          # point it at the same JSON-reliable coder model. FORESIGHT_LME_CONSOLIDATE_MODEL
          # overrides; otherwise it reuses the extraction model.
          consolidation_provider_opts: consolidation_provider_opts(base_url),
          reflect_max_iterations: env_integer("FORESIGHT_LME_REFLECT_ITERS", 4),
          reflect_timeout_ms: env_integer("FORESIGHT_LME_REFLECT_TIMEOUT_MS", 300_000)
        }

        Application.put_env(:foresight, :backend, Foresight.Backend.Store)
        Application.put_env(:foresight, :engine, engine_config)
        Application.put_env(:foresight, :ml, ml_config)

        # Enhancement A/B: the optional enhancements are OFF by default, so the
        # baseline arm is unchanged. A treatment arm flips them on via env:
        #   FORESIGHT_LME_ENTAILMENT=llm_judge  → grounded-reflect entailment gate
        #   FORESIGHT_LME_FUSION=normalized|hybrid → calibrated-score fusion
        orig_entailment = Application.get_env(:foresight, :entailment_verifier)
        orig_fusion = Application.get_env(:foresight, :recall_fusion)
        maybe_put_entailment(System.get_env("FORESIGHT_LME_ENTAILMENT"))
        maybe_put_fusion(System.get_env("FORESIGHT_LME_FUSION"))

        {:ok, warmup} =
          Foresight.Embedders.SentenceTransformers.embed("warmup", name: @python_worker_name)

        assert length(warmup) == 384
        {:ok, device} = Foresight.ML.PythonLocalWorker.device_info(name: @python_worker_name)
        embedder_device = device["embedder_device"] || "unknown"

        unless String.starts_with?(embedder_device, "mps") do
          flunk("[LME-REFLECT] embedder on #{inspect(embedder_device)}, not mps")
        end

        IO.puts("\n[LME-REFLECT] embedder device: #{embedder_device}")

        # Enhancement engagement confirmation: print the ACTIVE enhancement config so
        # a treatment arm can be proven to have engaged, not assumed.
        IO.puts(
          "[LME-REFLECT] enhancements: entailment=#{inspect(Application.get_env(:foresight, :entailment_verifier))} " <>
            "fusion=#{inspect(Application.get_env(:foresight, :recall_fusion))}"
        )

        IO.puts("[LME-REFLECT] answer/reflect model: #{answer_model}")

        IO.puts(
          "[LME-REFLECT] judge model: #{System.get_env("FORESIGHT_LME_JUDGE_MODEL", @default_judge_model)}"
        )

        on_exit(fn ->
          Logger.configure(level: logger_level)
          restore_env(:backend, original.backend)
          restore_env(:engine, original.engine)
          restore_env(:ml, original.ml)
          restore_env(:entailment_verifier, orig_entailment)
          restore_env(:recall_fusion, orig_fusion)
          Application.put_env(:foresight, Foresight.Repo, repo_config)
          PostgresHarness.stop!(harness)
        end)

        {:ok,
         path: path,
         base_url: base_url,
         answer_model: answer_model,
         hindsight_client: resolve_hindsight_client()}
    end
  end

  test "reflect vs fixed-reader answer accuracy (matched pair, independent judge)",
       context do
    if context[:skip] do
      IO.puts("\n[skip] #{context[:skip]}")
      assert true
    else
      path = context[:path]
      base_url = context[:base_url]
      answer_model = context[:answer_model]
      per_type = env_integer("FORESIGHT_LME_PER_TYPE", @default_per_type)
      seed = env_integer("FORESIGHT_LME_SEED", @default_seed)
      judge_model = System.get_env("FORESIGHT_LME_JUDGE_MODEL", @default_judge_model)
      hindsight_client = context[:hindsight_client]

      if hindsight_client do
        IO.puts("[LME-REFLECT] hindsight arm: ON (#{hindsight_client.base_url})")
      else
        IO.puts(
          "[LME-REFLECT] hindsight arm: OFF (set FORESIGHT_LME_HINDSIGHT_BASE_URL to enable)"
        )
      end

      instances =
        case System.get_env("FORESIGHT_LME_QIDS") do
          nil ->
            path
            |> LongMemEval.load!()
            |> maybe_filter_types(System.get_env("FORESIGHT_LME_TYPES"))
            |> stratified_sample(per_type, seed)

          csv ->
            keep = csv |> String.split(",", trim: true) |> MapSet.new()
            path |> LongMemEval.load!() |> Enum.filter(&MapSet.member?(keep, &1.id))
        end

      type_counts = Enum.frequencies_by(instances, & &1.question_type)
      IO.puts("\n[LME-REFLECT] scoring #{length(instances)} instances (seed=#{seed})")
      for {t, c} <- Enum.sort(type_counts), do: IO.puts("  #{t}: #{c}")

      # Instances are independent (each on its own Foresight + Hindsight bank), so with
      # a hosted, concurrency-tolerant reader (OpenRouter) they run in parallel. Wall
      # clock collapses from sum-of-instances to slowest-few. FORESIGHT_LME_CONCURRENCY
      # controls the fan-out (default 6); keep it ≤ the DB pool_size below.
      concurrency = env_integer("FORESIGHT_LME_CONCURRENCY", 6)
      total = length(instances)
      watcher = DegradationWatch.start()

      results =
        instances
        |> Enum.with_index(1)
        |> Task.async_stream(
          fn {inst, idx} ->
            r = score_instance(inst, base_url, answer_model, judge_model, hindsight_client)

            IO.puts(
              "[LME-REFLECT] #{idx}/#{total} #{inst.question_type} " <>
                "abstain=#{inst.abstention?} obs=#{r.obs_written} " <>
                "fixed=#{r.fixed_correct} reflect=#{r.reflect_correct} mode=#{r.reflect_mode}" <>
                hindsight_log(r)
            )

            Map.put(r, :type, inst.question_type)
          end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: env_integer("FORESIGHT_LME_INSTANCE_TIMEOUT_MS", 1_800_000)
        )
        |> Enum.map(fn {:ok, r} -> r end)

      degradation = stop_degradation_watch(watcher)

      report(results)
      write_results(results, per_type, seed)

      assert length(results) == length(instances)

      # A degraded arm must never be scored. On 2026-08-14 this bench ran with 10
      # extraction fallbacks and 5 skipped merges — the Foresight arm was storing raw
      # blobs instead of extracted facts, which is precisely the deficit worth -0.267
      # answer accuracy — and the harness would have printed a confident scoreboard if
      # it had not independently run out of wall-clock. The number would have entered
      # the record as a real result.
      #
      # Assert AFTER report/1 on purpose: the numbers are still printed so a failed run
      # is diagnosable, but the test fails so they cannot be quoted as a measurement.
      assert degradation.extraction_fallbacks == 0 and degradation.merges_skipped == 0, """
      REFUSING TO SCORE A DEGRADED RUN.

        retain extraction fallbacks: #{degradation.extraction_fallbacks}
        consolidation merges skipped: #{degradation.merges_skipped}

      Each fallback stored raw content instead of extracted facts; each skipped merge
      wrote no observation. Both silently lower the Foresight arm, so any accuracy
      computed above understates it and is not a valid head-to-head.

      Usual cause is LLM timeouts under load, not a code fault. Reduce inference
      contention (OLLAMA_NUM_PARALLEL), raise FORESIGHT_LLM_TIMEOUT_MS, and re-run.
      Set FORESIGHT_LME_ALLOW_DEGRADED=1 only to inspect a broken run — never to
      publish one.
      """
    end
  end

  # DegradationWatch is a real module with its own unit tests (it runs in the default
  # lane, unlike this hours-long :ml eval). Only the escape hatch lives here.
  defp stop_degradation_watch(watcher) do
    counts = DegradationWatch.stop(watcher)

    if System.get_env("FORESIGHT_LME_ALLOW_DEGRADED") == "1" do
      IO.puts("[LME-REFLECT] degradation observed but ALLOWED: #{inspect(counts)}")
      %{extraction_fallbacks: 0, merges_skipped: 0}
    else
      counts
    end
  end

  # --- per-instance: retain -> consolidate -> {fixed, reflect} -> judge ---

  defp score_instance(inst, base_url, answer_model, judge_model, hindsight_client) do
    bank_id = "lme-reflect-#{inst.id}"
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    with {:ok, _} <- retain_haystack(ctx, inst.memories) do
      obs_written = consolidate_bank(ctx)

      {fixed_answer, fixed_ok} =
        case generate_fixed(ctx, inst, base_url, answer_model) do
          {:ok, ans} -> {ans, judge(base_url, judge_model, inst, ans) == :correct}
          {:error, _} -> {"", false}
        end

      {reflect_answer, reflect_mode, reflect_ok} =
        case generate_reflect(ctx, inst) do
          {:ok, ans, mode} -> {ans, mode, judge(base_url, judge_model, inst, ans) == :correct}
          {:error, reason} -> {"", "error:#{inspect(reason)}", false}
        end

      # Third arm: the SAME sessions retained → consolidated → reflected
      # on a live Hindsight authority, scored by the SAME judge. nil when the arm is
      # off (no FORESIGHT_LME_HINDSIGHT_BASE_URL) so "not run" is never conflated
      # with "scored 0".
      {hindsight_answer, hindsight_ok, hindsight_state} =
        run_hindsight_arm(hindsight_client, bank_id, inst, base_url, judge_model)

      if System.get_env("FORESIGHT_LME_VERBOSE") == "1" do
        IO.puts(
          "    ── #{inst.question_type} | mode=#{reflect_mode} | fixed_ok=#{fixed_ok} reflect_ok=#{reflect_ok}"
        )

        IO.puts("    q:      #{truncate(inst.query, 240)}")
        IO.puts("    gold:   #{truncate(inst.reference_answer, 240)}")
        IO.puts("    fixed:  #{truncate(fixed_answer, 400)}")
        # Full (untruncated) reflect answer: the diagnostic that reveals WHETHER the
        # agentic answer is truncated mid-reasoning vs complete-but-wrong.
        IO.puts("    reflect(#{String.length(to_string(reflect_answer))}c): #{reflect_answer}")
        if hindsight_client, do: IO.puts("    hs:     #{truncate(hindsight_answer, 400)}")
      end

      %{
        abstention: inst.abstention?,
        obs_written: obs_written,
        fixed_correct: fixed_ok,
        reflect_correct: reflect_ok,
        reflect_mode: reflect_mode,
        hindsight_correct: hindsight_ok,
        hindsight_state: hindsight_state
      }
    else
      {:error, reason} ->
        IO.puts("[LME-REFLECT] WARN #{inst.id} retain failed: #{inspect(reason)}")

        %{
          abstention: inst.abstention?,
          obs_written: 0,
          fixed_correct: false,
          reflect_correct: false,
          reflect_mode: "retain_failed",
          hindsight_correct: nil,
          hindsight_state: "foresight_retain_failed"
        }
    end
  rescue
    error ->
      IO.puts("[LME-REFLECT] WARN #{inst.id} crashed: #{Exception.message(error)}")
      IO.puts(Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 1200))

      %{
        abstention: inst.abstention?,
        obs_written: 0,
        fixed_correct: false,
        reflect_correct: false,
        reflect_mode: "crashed",
        hindsight_correct: nil,
        hindsight_state: "foresight_crashed"
      }
  end

  # Hindsight arm: nil client → arm off (hindsight_correct nil). Otherwise drive the
  # live authority and score with the same judge; any HTTP failure is recorded as an
  # explicit error state (still nil correctness — a failed call is not a wrong answer).
  defp run_hindsight_arm(nil, _bank_id, _inst, _base_url, _judge_model),
    do: {"", nil, "off"}

  defp run_hindsight_arm(client, bank_id, inst, base_url, judge_model) do
    case HindsightBench.generate(client, bank_id, inst.memories, inst.query, inst.query_timestamp) do
      {:ok, answer, meta} ->
        ok = judge(base_url, judge_model, inst, answer) == :correct
        state = if meta.consolidated?, do: "ok", else: "ok_unconsolidated"
        {answer, ok, state}

      {:error, reason} ->
        IO.puts("[LME-REFLECT] hindsight arm error #{inst.id}: #{inspect(reason)}")
        {"", nil, "error:#{inspect(reason)}"}
    end
  end

  defp hindsight_log(%{hindsight_correct: nil}), do: ""
  defp hindsight_log(%{hindsight_correct: ok}), do: " hindsight=#{ok}"

  defp retain_haystack(ctx, memories) do
    memories
    |> Enum.chunk_every(5)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, acc} ->
      case Foresight.retain(ctx, %{"items" => chunk, "async" => false}) do
        {:ok, _} -> {:cont, {:ok, acc + length(chunk)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Synchronous consolidation so search_observations has real merged+embedded
  # observations. Returns observations_written (0 is a valid, honestly-reported
  # outcome — reflect can still aggregate in-context over recall).
  defp consolidate_bank(ctx) do
    case Foresight.consolidate(ctx, %{"async" => false}, []) do
      {:ok, result} ->
        if System.get_env("FORESIGHT_LME_VERBOSE") == "1" do
          IO.puts(
            "    consolidate: obs_created=#{result["observations_created"]} " <>
              "scopes_consolidated=#{result["scopes_consolidated"]} " <>
              "scopes_seen=#{result["scopes_seen"]}"
          )
        end

        result["observations_created"] || 0

      {:error, reason} ->
        IO.puts("    consolidate ERROR: #{inspect(reason)}")
        0
    end
  rescue
    error ->
      IO.puts("    consolidate CRASH: #{Exception.message(error)}")
      0
  end

  # Reader A (baseline): recall -> top-8 context -> plain completion.
  defp generate_fixed(ctx, inst, base_url, answer_model) do
    payload = %{
      "query" => inst.query,
      "query_timestamp" => inst.query_timestamp,
      "max_tokens" => 4000
    }

    case Foresight.recall(ctx, payload) do
      {:ok, %{"results" => results}} ->
        context =
          results
          |> Enum.take(8)
          |> Enum.map_join("\n---\n", &(&1["text"] || ""))

        prompt = """
        Answer the question using ONLY the context below. If the context does not \
        contain the answer, reply exactly: I don't know.

        Context:
        #{context}

        Question: #{inst.query}
        Answer concisely.
        """

        # Generous budget: a "thinking" reader (e.g. the 27b distilled) spends
        # tokens on reasoning before the answer; 256 truncated it mid-sentence.
        {:ok, complete(base_url, answer_model, prompt, 2048)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Reader B (treatment): the agentic reflect loop. Returns the answer text and
  # the trace mode ("agentic" or the fixed fallback) so the report can be honest
  # about whether the local model actually drove tool-calling.
  defp generate_reflect(ctx, inst) do
    # budget drives reflect_max_iterations' multiplier ("low" 0.5x / "mid" 1.0x /
    # "high" 2.0x). Set it explicitly so the eval's operating point is reproducible
    # and self-documenting regardless of the library default (which is now "mid").
    # "mid" is the 1.0x production operating point; combined with
    # FORESIGHT_LME_REFLECT_ITERS this gives the agentic loop a fair iteration
    # budget rather than starving it into premature fixed-pipeline fallback.
    payload = %{
      "query" => inst.query,
      "query_timestamp" => inst.query_timestamp,
      "budget" => System.get_env("FORESIGHT_LME_REFLECT_BUDGET", "mid"),
      "max_tokens" => 512
    }

    case Foresight.reflect(ctx, payload) do
      {:ok, result} ->
        mode = get_in(result, ["trace", "mode"]) || "unknown"

        if System.get_env("FORESIGHT_LME_VERBOSE") == "1" do
          tcs = get_in(result, ["trace", "tool_calls"]) || []
          n = get_in(result, ["trace", "tools_called"]) || length(tcs)

          summary =
            tcs
            |> Enum.map(fn tc -> "#{tc["tool"]}(#{truncate(to_string(tc["query"]), 40)})" end)
            |> Enum.join(", ")

          IO.puts(
            "    tools:  #{n} — #{if summary == "", do: "(none — answered from pre-seed)", else: summary}"
          )
        end

        {:ok, to_string(result["text"] || ""), mode}

      # Foresight leaks the timed_ms wrapper {{:error, reason}, ms} on some reflect
      # error paths (a real robustness bug). Unwrap it.
      {{:error, reason}, _ms} ->
        reflect_answer_from_error(reason)

      {:error, reason} ->
        reflect_answer_from_error(reason)
    end
  end

  # When the reflect final structured output is malformed/truncated JSON (weaker
  # readers wrap or cut off the ReflectResponse), the ANSWER TEXT is still present in
  # the raw body. The judge grades the answer, so recover the "text" leniently rather
  # than discarding a correct answer as a failure. If no text is recoverable it is a
  # genuine reflect failure.
  defp reflect_answer_from_error(reason) do
    with raw when is_binary(raw) <- reflect_raw_from_error(reason),
         text when is_binary(text) and text != "" <- lenient_text_field(raw) do
      {:ok, text, "recovered_text"}
    else
      _ -> {:error, reason}
    end
  end

  defp reflect_raw_from_error({:structured_output_error, {:invalid_json, %{data: raw}}})
       when is_binary(raw),
       do: raw

  defp reflect_raw_from_error(_reason), do: nil

  # Grab the first "text": "..." value even from truncated/otherwise-invalid JSON,
  # honouring backslash escapes; unescape it back to a plain string.
  defp lenient_text_field(raw) do
    case Regex.run(~r/"text"\s*:\s*"((?:[^"\\]|\\.)*)"/, raw) do
      [_, captured] ->
        captured
        |> String.replace("\\n", "\n")
        |> String.replace("\\\"", "\"")
        |> String.replace("\\\\", "\\")

      _ ->
        nil
    end
  end

  # --- judge (independent model, plain completion) ---

  defp judge(base_url, model, %{abstention?: true} = _inst, answer) do
    prompt = """
    A question was asked whose answer is NOT present in the provided memory. The correct \
    behaviour is to ABSTAIN — to say the information is not available / unknown, and NOT to \
    fabricate a specific answer.

    Model answer: #{truncate(answer, 1500)}

    Did the model correctly abstain (decline / say it doesn't know / say the info isn't available)?
    Reply with exactly one word: CORRECT (it abstained) or INCORRECT (it fabricated an answer).
    """

    classify(base_url, model, prompt)
  end

  defp judge(base_url, model, inst, answer) do
    prompt = """
    You are grading whether a model's answer matches the reference answer to a question.
    Award CORRECT if the model answer contains the key information in the reference answer \
    (semantically equivalent; wording may differ). Award INCORRECT otherwise, including if \
    the model failed to answer.

    Question: #{inst.query}
    Reference answer: #{inst.reference_answer}
    Model answer: #{truncate(answer, 1500)}

    Reply with exactly one word: CORRECT or INCORRECT.
    """

    classify(base_url, model, prompt)
  end

  defp classify(base_url, model, prompt) do
    case chat(base_url, model, prompt, 16) do
      {:ok, content} ->
        text = String.upcase(content)

        if String.contains?(text, "CORRECT") and not String.contains?(text, "INCORRECT"),
          do: :correct,
          else: :incorrect

      {:error, other} ->
        IO.puts("[LME-REFLECT] judge call failed: #{inspect(other)}")
        :incorrect
    end
  end

  defp complete(base_url, model, prompt, max_tokens) do
    case chat(base_url, model, prompt, max_tokens) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  defp chat(base_url, model, prompt, max_tokens) do
    body =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => prompt}],
        "temperature" => 0,
        "max_tokens" => max_tokens
      })

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    # Bearer auth for the fixed reader + judge (this raw :httpc path, unlike the
    # LlmCore reflect path). Local endpoints (LM Studio) ignore it; OpenRouter and
    # other hosted gateways require it (else 401 "No auth credentials found").
    api_key = System.get_env("FORESIGHT_LLM_API_KEY", "lm-studio")

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"authorization", String.to_charlist("Bearer " <> api_key)}
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(:post, request, [{:timeout, 150_000}], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, raw}} when status in 200..299 ->
        content =
          raw
          |> Jason.decode!()
          |> get_in(["choices", Access.at(0), "message", "content"])
          |> to_string()

        {:ok, content}

      other ->
        {:error, other}
    end
  end

  # --- reporting ---

  defp report(results) do
    agentic = Enum.count(results, &(&1.reflect_mode == "agentic"))
    total_obs = Enum.sum(Enum.map(results, & &1.obs_written))

    IO.puts("\n" <> String.duplicate("=", 78))
    IO.puts("CHECKPOINT C — reflect vs fixed-reader answer accuracy (matched pair)")
    IO.puts(String.duplicate("=", 78))

    IO.puts(
      "reflect agentic-path ratio: #{agentic}/#{length(results)} " <>
        "(#{pct(agentic, length(results))}%)   observations written total: #{total_obs}"
    )

    IO.puts(String.duplicate("-", 78))
    IO.puts(String.pad_trailing("question_type", 28) <> "n     fixed   reflect  delta")

    results
    |> Enum.group_by(& &1.type)
    |> Enum.sort()
    |> Enum.each(fn {type, group} ->
      f = accuracy(group, :fixed_correct)
      r = accuracy(group, :reflect_correct)

      IO.puts(
        String.pad_trailing(type, 28) <>
          String.pad_trailing("#{length(group)}", 6) <>
          String.pad_trailing(fmt(f), 8) <>
          String.pad_trailing(fmt(r), 9) <> fmt_delta(r - f)
      )
    end)

    IO.puts(String.duplicate("-", 78))
    paired = Stats.paired(Enum.map(results, &{&1.fixed_correct, &1.reflect_correct}))

    IO.puts(
      String.pad_trailing("OVERALL", 28) <>
        String.pad_trailing("#{paired.n}", 6) <>
        String.pad_trailing(fmt(paired.a_accuracy), 8) <>
        String.pad_trailing(fmt(paired.b_accuracy), 9) <> fmt_delta(paired.delta)
    )

    IO.puts(String.duplicate("-", 78))
    IO.puts("fixed   95% CI: #{fmt_ci(paired.a_ci)}   (n=#{paired.n})")
    IO.puts("reflect 95% CI: #{fmt_ci(paired.b_ci)}   (n=#{paired.n})")

    IO.puts(
      "paired (reflect−fixed): delta #{fmt_delta(paired.delta)}   " <>
        "discordant fixed-only=#{paired.a_only} reflect-only=#{paired.b_only}   " <>
        "McNemar exact p=#{fmt(paired.mcnemar_p)}"
    )

    IO.puts(
      "NOTE: Wilson 95% CIs; paired McNemar. Single run — no A/A noise floor. " <>
        "Run ≥3 replicates (fixed seed) → Stats.replicate_summary to bound nondeterminism."
    )

    report_hindsight(results)

    IO.puts(String.duplicate("=", 78))
  end

  # The scoreboard: Foresight-reflect vs Hindsight-reflect, matched reader,
  # same judge, same instances. Computed ONLY over instances where the Hindsight arm
  # actually produced an answer (hindsight_correct != nil), and it reports that
  # coverage explicitly so a partial run can never masquerade as a full one.
  defp report_hindsight(results) do
    ran = Enum.filter(results, &(&1.hindsight_correct != nil))

    IO.puts(String.duplicate("=", 78))

    if ran == [] do
      IO.puts(
        "FORESIGHT vs HINDSIGHT: arm not run (set FORESIGHT_LME_HINDSIGHT_BASE_URL to a " <>
          "matched-reader authority). No head-to-head number this run."
      )
    else
      IO.puts(
        "FORESIGHT vs HINDSIGHT (reflect, matched reader) — covered " <>
          "#{length(ran)}/#{length(results)} instances"
      )

      IO.puts(String.duplicate("-", 78))
      IO.puts(String.pad_trailing("question_type", 28) <> "n     forsght hndsght  delta")

      ran
      |> Enum.group_by(& &1.type)
      |> Enum.sort()
      |> Enum.each(fn {type, group} ->
        f = accuracy(group, :reflect_correct)
        h = accuracy(group, :hindsight_correct)

        IO.puts(
          String.pad_trailing(type, 28) <>
            String.pad_trailing("#{length(group)}", 6) <>
            String.pad_trailing(fmt(f), 8) <>
            String.pad_trailing(fmt(h), 9) <> fmt_delta(f - h)
        )
      end)

      # Stats.paired: arm A = Foresight reflect, arm B = Hindsight reflect.
      # delta (b − a) = Hindsight − Foresight, so a POSITIVE Foresight lead is −delta.
      paired = Stats.paired(Enum.map(ran, &{&1.reflect_correct, &1.hindsight_correct}))

      IO.puts(String.duplicate("-", 78))

      IO.puts(
        String.pad_trailing("OVERALL", 28) <>
          String.pad_trailing("#{paired.n}", 6) <>
          String.pad_trailing(fmt(paired.a_accuracy), 8) <>
          String.pad_trailing(fmt(paired.b_accuracy), 9) <>
          fmt_delta(paired.a_accuracy - paired.b_accuracy)
      )

      IO.puts(String.duplicate("-", 78))
      IO.puts("foresight 95% CI: #{fmt_ci(paired.a_ci)}   (n=#{paired.n})")
      IO.puts("hindsight 95% CI: #{fmt_ci(paired.b_ci)}   (n=#{paired.n})")

      IO.puts(
        "paired (foresight−hindsight): delta #{fmt_delta(paired.a_accuracy - paired.b_accuracy)}   " <>
          "discordant foresight-only=#{paired.a_only} hindsight-only=#{paired.b_only}   " <>
          "McNemar exact p=#{fmt(paired.mcnemar_p)}"
      )

      IO.puts(
        "VERDICT GUIDE: parity = |delta| within the ±0.1 n=30 nondeterminism band. " <>
          "One run is a noisy point — require ≥2 runs (or the band) before calling it."
      )
    end
  end

  defp fmt_ci({lo, hi}), do: "[#{fmt(lo)}, #{fmt(hi)}]"

  defp accuracy([], _key), do: 0.0

  defp accuracy(group, key) do
    (Enum.count(group, &Map.get(&1, key)) / length(group)) |> Float.round(4)
  end

  defp fmt(f), do: :erlang.float_to_binary(f, decimals: 3)
  defp fmt_delta(d) when d >= 0, do: "+" <> :erlang.float_to_binary(d, decimals: 3)
  defp fmt_delta(d), do: :erlang.float_to_binary(d, decimals: 3)
  defp pct(_n, 0), do: 0
  defp pct(n, total), do: round(n / total * 100)

  defp write_results(results, per_type, seed) do
    by_type =
      results
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, group} ->
        {type,
         %{
           "n" => length(group),
           "fixed_accuracy" => accuracy(group, :fixed_correct),
           "reflect_accuracy" => accuracy(group, :reflect_correct)
         }}
      end)

    paired = Stats.paired(Enum.map(results, &{&1.fixed_correct, &1.reflect_correct}))

    payload = %{
      "overall" => %{
        "n" => paired.n,
        "fixed_accuracy" => paired.a_accuracy,
        "reflect_accuracy" => paired.b_accuracy,
        "fixed_ci95" => Tuple.to_list(paired.a_ci),
        "reflect_ci95" => Tuple.to_list(paired.b_ci),
        "paired_delta" => paired.delta,
        "discordant_fixed_only" => paired.a_only,
        "discordant_reflect_only" => paired.b_only,
        "mcnemar_exact_p" => paired.mcnemar_p
      },
      "reflect_agentic_ratio" =>
        Enum.count(results, &(&1.reflect_mode == "agentic")) / max(length(results), 1),
      "observations_written_total" => Enum.sum(Enum.map(results, & &1.obs_written)),
      "by_type" => by_type,
      "hindsight" => hindsight_payload(results),
      "config" => %{"per_type" => per_type, "seed" => seed, "corpus" => "longmemeval_oracle"}
    }

    path = Path.join(System.tmp_dir!(), "foresight_lme_reflect_judge_results.json")
    File.write!(path, Jason.encode!(payload, pretty: true))
    IO.puts("[LME-REFLECT] results written to #{path}")
  end

  # Foresight-vs-Hindsight block for the results JSON. `"ran": false` when the arm
  # was off — the number is absent, never faked as 0. When on, `covered` records how
  # many of the N instances Hindsight actually answered.
  defp hindsight_payload(results) do
    ran = Enum.filter(results, &(&1.hindsight_correct != nil))

    if ran == [] do
      %{"ran" => false}
    else
      paired = Stats.paired(Enum.map(ran, &{&1.reflect_correct, &1.hindsight_correct}))

      %{
        "ran" => true,
        "covered" => length(ran),
        "total" => length(results),
        "foresight_reflect_accuracy" => paired.a_accuracy,
        "hindsight_reflect_accuracy" => paired.b_accuracy,
        "foresight_ci95" => Tuple.to_list(paired.a_ci),
        "hindsight_ci95" => Tuple.to_list(paired.b_ci),
        "paired_delta_foresight_minus_hindsight" => paired.a_accuracy - paired.b_accuracy,
        "discordant_foresight_only" => paired.a_only,
        "discordant_hindsight_only" => paired.b_only,
        "mcnemar_exact_p" => paired.mcnemar_p
      }
    end
  end

  # --- helpers ---

  defp maybe_filter_types(instances, nil), do: instances

  defp maybe_filter_types(instances, csv) do
    keep = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
    Enum.filter(instances, &MapSet.member?(keep, &1.question_type))
  end

  # Enhancement A/B knobs: map env values to the off-by-default enhancement config.
  defp maybe_put_entailment("llm_judge"),
    do:
      Application.put_env(
        :foresight,
        :entailment_verifier,
        Foresight.Reflect.EntailmentVerifiers.LLMJudge
      )

  defp maybe_put_entailment("noop"),
    do:
      Application.put_env(
        :foresight,
        :entailment_verifier,
        Foresight.Reflect.EntailmentVerifiers.Noop
      )

  defp maybe_put_entailment(_), do: :ok

  defp maybe_put_fusion(mode) when mode in ["normalized", "hybrid", "rrf"],
    do: Application.put_env(:foresight, :recall_fusion, mode: String.to_atom(mode))

  defp maybe_put_fusion(_), do: :ok

  defp stratified_sample(instances, per_type, seed) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})

    instances
    |> Enum.group_by(& &1.question_type)
    |> Enum.sort_by(fn {type, _} -> type end)
    |> Enum.flat_map(fn {_type, group} -> group |> Enum.shuffle() |> Enum.take(per_type) end)
  end

  defp env_integer(key, default) do
    case System.get_env(key) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  # The Hindsight arm is OFF unless FORESIGHT_LME_HINDSIGHT_BASE_URL points at a live
  # authority. That authority MUST run reflect+consolidation on the SAME reader as
  # Foresight (gpt-oss:20b) for the number to be fair — see
  # scripts/start-hindsight-fixture-authority.sh.
  defp resolve_hindsight_client do
    case System.get_env("FORESIGHT_LME_HINDSIGHT_BASE_URL") do
      nil ->
        nil

      "" ->
        nil

      base_url ->
        api_key = System.get_env("FORESIGHT_LME_HINDSIGHT_API_KEY", "sk-foresight-fixtures-dev")
        HindsightBench.client(base_url, api_key)
    end
  end

  # Provider opts pointing atomic-fact extraction at a JSON-reliable model. nil
  # (env unset) → extraction falls back to the engine's reader provider_opts.
  defp extraction_provider_opts(base_url) do
    json_model_provider_opts(base_url, "FORESIGHT_LME_EXTRACT_MODEL")
  end

  # Consolidation JSON model: FORESIGHT_LME_CONSOLIDATE_MODEL, falling back to the
  # extraction model (both are structured-JSON roles wanting the same coder).
  defp consolidation_provider_opts(base_url) do
    json_model_provider_opts(base_url, "FORESIGHT_LME_CONSOLIDATE_MODEL") ||
      extraction_provider_opts(base_url)
  end

  defp json_model_provider_opts(base_url, env_key) do
    case System.get_env(env_key) do
      nil ->
        nil

      model ->
        [
          base_url: base_url,
          api_key: System.get_env("FORESIGHT_LLM_API_KEY", "lm-studio"),
          model: model,
          timeout: 180_000
        ]
    end
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp truncate(_text, _max), do: ""

  defp resolve_python_executable do
    env = System.get_env("FORESIGHT_ML_PYTHON")
    venv = Path.expand("~/.cache/foresight-ml-venv/bin/python")

    cond do
      is_binary(env) and env != "" and File.exists?(env) -> env
      File.exists?(venv) -> venv
      true -> nil
    end
  end

  defp verify_mps_device!(python) do
    script =
      "import torch,json;print(json.dumps({\"mps\": torch.backends.mps.is_available()}))"

    case System.cmd(python, ["-c", script], stderr_to_stdout: true) do
      {out, 0} ->
        case Jason.decode(String.trim(out)) do
          {:ok, %{"mps" => true}} -> :ok
          _ -> flunk("[LME-REFLECT] MPS not available: #{out}")
        end

      {out, code} ->
        flunk("[LME-REFLECT] python MPS check failed (#{code}): #{out}")
    end
  end

  defp llm_reachable?(base_url) do
    url = String.trim_trailing(base_url, "/") <> "/models"

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 3_000}], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> true
      _ -> false
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)
end
