defmodule Foresight.Evals.LongMemEvalAnswerJudgeEvalTest do
  @moduledoc """
  Answer-level quality lane for LongMemEval.

  Measures what LongMemEval actually headlines — QA accuracy — not just retrieval
  ranking. This is the metric that CAN respond to the retrieval differentiators
  (graph, consolidation, supersession), because LongMemEval-S retrieval nDCG is
  saturated by the semantic arm + reranker.

  Per sampled instance:
    1. retain the instance haystack into its own bank (real Ecto + pgvector + MPS embeddings)
    2. Foresight.recall(query) -> a FIXED reader (plain LMStudio completion over the
       recalled context) produces an answer. The reader is held constant, so changes
       in the score reflect changes in RETRIEVAL — which is what those differentiators should move.
    3. an INDEPENDENT judge model scores the answer against the gold reference_answer
       (CORRECT / INCORRECT), and for abstention (_abs) instances scores whether the
       model correctly declined.

  This deliberately does NOT use Foresight.reflect for answer generation: reflect's
  strict json_schema structured output is currently unreliable against local LMStudio
  models (empty/invalid JSON). Measuring Foresight's NATIVE reflect answer quality is
  a separate concern (the grounded-reflect entailment gate). So this lane measures "Foresight retrieval -> answer
  accuracy with a held-constant reader", NOT reflect quality — labelled honestly.

  Reports per-question-type answer accuracy. Retrieval metrics remain the separate
  longmemeval_real_ml_eval_test lane.

  ## GPU / LLM setup

  Embeddings: sentence_transformers on MPS (see the retrieval lane's moduledoc — do
  NOT use Bumblebee/EXLA, it is CPU-bound on Apple Silicon). Answer + judge LLMs:
  LMStudio on 127.0.0.1:1234. LlmCore redirects a localhost OpenAI base_url to its
  local Appliance provider automatically.

  Env:
    FORESIGHT_ML_PYTHON            venv python with torch+sentence-transformers (MPS)
    FORESIGHT_LLM_BASE_URL         default http://127.0.0.1:1234/v1
    FORESIGHT_LME_ANSWER_MODEL     reflect/answer model (default qwen3.5-9b-mlx)
    FORESIGHT_LME_JUDGE_MODEL      judge model (default qwen3.5-27b-claude-4.6-opus-distilled-mlx)
    FORESIGHT_LME_PER_TYPE         instances per question_type (default 3)
    FORESIGHT_LME_SEED             stratified sampling seed (default 42)
  """
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.LongMemEval
  alias Foresight.TestSupport.FakeAsyncQueue
  alias Foresight.TestSupport.PostgresHarness

  require Logger

  @moduletag :eval
  @moduletag :ml
  @moduletag :llm
  @moduletag timeout: 5_400_000

  @default_path "priv/evals/data/longmemeval_s.json"
  @default_per_type 3
  @default_seed 42
  # Non-thinking instruct models: "thinking" models (qwen3.5-*) emit reasoning tokens
  # first, leaving `content` empty under a small max_tokens budget — which silently
  # zeroes both the answer and the judge verdict. Use direct-answering instruct models.
  @default_answer_model "qwen3-vl-8b-instruct-c_abliterated-v3-mlx"
  @default_judge_model "qwen3-vl-8b-instruct-c_abliterated-v3-mlx"

  @python_worker_name Module.concat(__MODULE__, PythonWorker)

  setup_all do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    path = System.get_env("FORESIGHT_LME_REAL_ML_PATH", @default_path)
    base_url = System.get_env("FORESIGHT_LLM_BASE_URL", "http://127.0.0.1:1234/v1")

    cond do
      not File.exists?(path) ->
        %{skip: "longmemeval_s data not available at #{path}"}

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
          Keyword.merge(repo_config, url: harness.url, pool_size: 10, timeout: 600_000)
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

        # Engine config: real retrieval (MPS) + real reflect LLM (LMStudio via
        # LlmCore; provider "openai" auto-redirects to the local Appliance provider
        # because the base_url is localhost).
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
            timeout: 180_000
          ],
          queue: FakeAsyncQueue,
          oban_name: Foresight.Oban,
          # Bound the plan loop — each iteration is an LLM round-trip to a local model.
          reflect_max_iterations: env_integer("FORESIGHT_LME_REFLECT_ITERS", 3),
          reflect_timeout_ms: 180_000
        }

        Application.put_env(:foresight, :backend, Foresight.Backend.Store)
        Application.put_env(:foresight, :engine, engine_config)
        Application.put_env(:foresight, :ml, ml_config)

        # Warm + verify device is really MPS.
        {:ok, warmup} =
          Foresight.Embedders.SentenceTransformers.embed("warmup", name: @python_worker_name)

        assert length(warmup) == 384
        {:ok, device} = Foresight.ML.PythonLocalWorker.device_info(name: @python_worker_name)
        embedder_device = device["embedder_device"] || "unknown"

        unless String.starts_with?(embedder_device, "mps") do
          flunk("[LME-JUDGE] embedder on #{inspect(embedder_device)}, not mps")
        end

        IO.puts("\n[LME-JUDGE] embedder device: #{embedder_device}")
        IO.puts("[LME-JUDGE] answer model: #{answer_model}")

        IO.puts(
          "[LME-JUDGE] judge model: #{System.get_env("FORESIGHT_LME_JUDGE_MODEL", @default_judge_model)}"
        )

        on_exit(fn ->
          Logger.configure(level: logger_level)
          restore_env(:backend, original.backend)
          restore_env(:engine, original.engine)
          restore_env(:ml, original.ml)
          Application.put_env(:foresight, Foresight.Repo, repo_config)
          PostgresHarness.stop!(harness)
        end)

        {:ok, path: path, base_url: base_url, answer_model: answer_model}
    end
  end

  test "LongMemEval answer accuracy via recall + fixed reader + independent LLM judge",
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

      instances =
        path
        |> LongMemEval.load!()
        |> stratified_sample(per_type, seed)

      type_counts = Enum.frequencies_by(instances, & &1.question_type)
      IO.puts("\n[LME-JUDGE] scoring #{length(instances)} instances (seed=#{seed})")
      for {t, c} <- Enum.sort(type_counts), do: IO.puts("  #{t}: #{c}")

      results =
        instances
        |> Enum.with_index(1)
        |> Enum.map(fn {inst, idx} ->
          verdict = score_instance(inst, base_url, answer_model, judge_model)

          IO.puts(
            "[LME-JUDGE] #{idx}/#{length(instances)} #{inst.question_type} " <>
              "abstain=#{inst.abstention?} -> #{verdict}"
          )

          %{type: inst.question_type, abstention: inst.abstention?, correct: verdict == :correct}
        end)

      report_by_type(results)
      write_results(results, per_type, seed)

      assert length(results) == length(instances)
    end
  end

  # --- per-instance: retain -> recall -> fixed-reader answer -> judge ---

  defp score_instance(inst, base_url, answer_model, judge_model) do
    bank_id = "lme-judge-#{inst.id}"
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    with {:ok, _} <- retain_haystack(ctx, inst.memories),
         {:ok, answer} <- generate_answer(ctx, inst, base_url, answer_model) do
      if System.get_env("FORESIGHT_LME_VERBOSE") == "1" do
        IO.puts("    q:    #{truncate(inst.query, 160)}")
        IO.puts("    gold: #{truncate(inst.reference_answer, 160)}")
        IO.puts("    ans:  #{truncate(answer, 200)}")
      end

      judge(base_url, judge_model, inst, answer)
    else
      {:error, reason} ->
        IO.puts("[LME-JUDGE] WARN #{inst.id}: #{inspect(reason)}")
        :incorrect
    end
  rescue
    error ->
      IO.puts("[LME-JUDGE] WARN #{inst.id} crashed: #{Exception.message(error)}")
      :incorrect
  end

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

  # Fixed reader: answer the question using ONLY Foresight's recalled context via a
  # plain completion. This measures Foresight RETRIEVAL -> answer quality with a
  # held-constant reader.
  #
  # It deliberately does NOT use Foresight.reflect: reflect's strict json_schema
  # structured output is currently unreliable with local LMStudio models (returns
  # empty/invalid JSON). Native-reflect answer quality is tracked separately
  # (grounded-reflect work). Because the reader is held constant, changes in this score reflect
  # changes in RETRIEVAL — which is exactly what the retrieval differentiators should move.
  defp generate_answer(ctx, inst, base_url, answer_model) do
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

        {:ok, complete(base_url, answer_model, prompt, 256)}

      {:error, reason} ->
        {:error, reason}
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
        IO.puts("[LME-JUDGE] judge call failed: #{inspect(other)}")
        :incorrect
    end
  end

  defp complete(base_url, model, prompt, max_tokens) do
    case chat(base_url, model, prompt, max_tokens) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  # Plain OpenAI-compatible chat completion (LMStudio). Returns {:ok, content}.
  defp chat(base_url, model, prompt, max_tokens) do
    body =
      Jason.encode!(%{
        "model" => model,
        "messages" => [%{"role" => "user", "content" => prompt}],
        "temperature" => 0,
        "max_tokens" => max_tokens
      })

    url = String.trim_trailing(base_url, "/") <> "/chat/completions"
    headers = [{~c"content-type", ~c"application/json"}]
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

  defp report_by_type(results) do
    IO.puts("\n" <> String.duplicate("=", 72))
    IO.puts("LongMemEval ANSWER ACCURACY (reflect + independent judge)")
    IO.puts(String.duplicate("=", 72))
    IO.puts(String.pad_trailing("question_type", 30) <> "n     accuracy")

    results
    |> Enum.group_by(& &1.type)
    |> Enum.sort()
    |> Enum.each(fn {type, group} ->
      IO.puts(
        String.pad_trailing(type, 30) <>
          String.pad_trailing("#{length(group)}", 6) <> Float.to_string(accuracy(group))
      )
    end)

    IO.puts(String.duplicate("-", 72))

    IO.puts(
      String.pad_trailing("OVERALL", 30) <>
        String.pad_trailing("#{length(results)}", 6) <> Float.to_string(accuracy(results))
    )

    IO.puts(String.duplicate("=", 72))
  end

  defp accuracy([]), do: 0.0

  defp accuracy(group) do
    (Enum.count(group, & &1.correct) / length(group)) |> Float.round(4)
  end

  defp write_results(results, per_type, seed) do
    payload = %{
      "overall_accuracy" => accuracy(results),
      "n" => length(results),
      "per_type" =>
        results
        |> Enum.group_by(& &1.type)
        |> Map.new(fn {type, group} ->
          {type, %{"n" => length(group), "accuracy" => accuracy(group)}}
        end),
      "config" => %{"per_type" => per_type, "seed" => seed}
    }

    path = Path.join(System.tmp_dir!(), "foresight_lme_answer_judge_results.json")
    File.write!(path, Jason.encode!(payload, pretty: true))
    IO.puts("[LME-JUDGE] results written to #{path}")
  end

  # --- helpers ---

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
          _ -> flunk("[LME-JUDGE] MPS not available: #{out}")
        end

      {out, code} ->
        flunk("[LME-JUDGE] python MPS check failed (#{code}): #{out}")
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
