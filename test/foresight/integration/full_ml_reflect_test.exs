defmodule Foresight.Integration.FullMlReflectTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.RecallQuality
  alias Foresight.LLMs.LlmCore
  alias Foresight.Profiles.FullMLAuthority
  alias Foresight.Prompts.{ReflectPlanResponse, ReflectResponse}
  alias Foresight.TestSupport.{FakeAsyncQueue, PostgresHarness}

  @moduletag :full_ml_e2e
  @moduletag :nightly
  @moduletag timeout: 1_200_000

  @embedding_serving_name Module.concat(__MODULE__, EmbeddingServing)
  @reranker_serving_name Module.concat(__MODULE__, RerankerServing)

  setup do
    cond do
      System.get_env("FORESIGHT_RUN_FULL_ML_E2E") != "1" ->
        {:ok,
         skip:
           "Set FORESIGHT_RUN_FULL_ML_E2E=1 to run the long-running full-stack ML qualification lane."}

      not llm_endpoint_available?() ->
        {:ok,
         skip: "Configured LLM endpoint is not reachable for the full ML qualification lane."}

      true ->
        :ok
    end
  end

  setup_all do
    cond do
      System.get_env("FORESIGHT_RUN_FULL_ML_E2E") != "1" ->
        :ok

      not llm_endpoint_available?() ->
        :ok

      true ->
        harness = PostgresHarness.start!()
        repo_config = Application.get_env(:foresight, Foresight.Repo, [])
        original_backend = Application.get_env(:foresight, :backend)
        original_engine = Application.get_env(:foresight, :engine)
        original_ml = Application.get_env(:foresight, :ml)

        full_ml_env =
          %{
            "FORESIGHT_LOCAL_ML_BACKEND" => local_ml_backend(),
            "FORESIGHT_LLM_PROVIDER" => llm_provider(),
            "FORESIGHT_LLM_BASE_URL" => llm_base_url(),
            "FORESIGHT_LLM_API_KEY" => llm_api_key(),
            "FORESIGHT_LLM_MODEL" => llm_model!()
          }
          |> maybe_put_sentence_transformers_python()

        profile =
          FullMLAuthority.build(full_ml_env)

        Application.put_env(
          :foresight,
          Foresight.Repo,
          Keyword.merge(repo_config,
            url: harness.url,
            pool_size: 10,
            timeout: 180_000
          )
        )

        start_supervised!(Foresight.Repo)

        migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

        {:ok, _migrated, _apps} =
          Migrator.with_repo(Foresight.Repo, fn repo ->
            Migrator.run(repo, migrations_path, :up, all: true)
          end)

        start_supervised!({FakeAsyncQueue, []})
        FakeAsyncQueue.reset!()
        maybe_start_bumblebee_servings!(profile)

        ml_config =
          profile.resolved_config.ml
          |> Enum.into([])
          |> maybe_put_bumblebee_serving_names()

        engine_config =
          profile.engine_config
          |> Enum.into([])
          |> Keyword.put(:queue, FakeAsyncQueue)
          |> Keyword.put(:reflect_max_iterations, 3)
          |> maybe_put_bumblebee_reranker_serving_name(profile)

        Application.put_env(:foresight, :backend, Foresight.Backend.Store)
        Application.put_env(:foresight, :engine, engine_config)
        Application.put_env(:foresight, :ml, ml_config)

        warm_local_ml_path!(
          Keyword.fetch!(engine_config, :embedder),
          Keyword.fetch!(engine_config, :reranker),
          ml_config
        )

        warm_llm_reflect_path!()

        on_exit(fn ->
          restore_env(:foresight, Foresight.Repo, repo_config)
          restore_env(:foresight, :backend, original_backend)
          restore_env(:foresight, :engine, original_engine)
          restore_env(:foresight, :ml, original_ml)
          PostgresHarness.stop!(harness)
        end)

        :ok
    end
  end

  test "retain -> recall -> reflect works with the real ML stack on a diary-style corpus" do
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "diary-ml-bank"}

    {_bank, put_bank_ms} =
      timed_ok!("put_bank", 30_000, fn ->
        Foresight.put_bank(ctx, "diary-ml-bank", %{
          "name" => "Diary ML Bank",
          "mission" => "Remember diary facts faithfully and avoid invention.",
          "disposition" => %{"skepticism" => 7, "empathy" => 6}
        })
      end)

    {%{"success" => true, "items_count" => 1}, retain_ms} =
      timed_ok!("retain", 420_000, fn ->
        Foresight.retain(ctx, %{
          "async" => false,
          "items" => [
            %{
              "content" =>
                "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven.",
              "context" => "diary",
              "type" => "world",
              "tags" => ["diary", "project:foresight", "person:alice", "place:oxford"]
            }
          ]
        })
      end)

    query = "What did Alice and I decide about the Foresight cutover after Oxford?"

    {%{"results" => [first | _], "trace" => trace}, recall_ms} =
      timed_ok!("recall", 180_000, fn ->
        Foresight.recall(ctx, %{
          "query" => query,
          "trace" => true
        })
      end)

    assert topic_match?(first["text"], ["ashmolean", "oxford", "cutover", "lmstudio"])
    assert trace["reranker"]["active"] == true
    assert trace["reranker"]["count"] >= 1

    schema = %{
      "title" => "diary_memory_reflect",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["summary", "grounded"],
      "properties" => %{
        "summary" => %{"type" => "string"},
        "grounded" => %{"type" => "boolean"}
      }
    }

    {%{
       "text" => text,
       "structured_output" => %{"summary" => summary, "grounded" => grounded},
       "usage" => %{"total_tokens" => total_tokens},
       "trace" => %{"llm_calls" => llm_calls, "timings_ms" => timings_ms}
     }, reflect_ms} =
      timed_ok!("reflect", 420_000, fn ->
        Foresight.reflect(
          ctx,
          %{
            "query" => query,
            "trace" => true,
            "response_schema" => schema
          },
          reflect_timeout_ms: 420_000
        )
      end)

    assert String.trim(text) != ""
    assert topic_match?(text, ["foresight", "cutover", "oxford", "lmstudio"])
    assert is_binary(summary)
    assert String.trim(summary) != ""
    assert topic_match?(summary, ["foresight", "cutover", "oxford", "lmstudio"])
    assert grounded in [true, false]
    assert total_tokens > 0
    assert Enum.map(llm_calls, & &1["phase"]) == ["plan", "synthesize", "structured_output"]
    assert is_integer(timings_ms["recall_ms"])
    assert is_integer(timings_ms["planner_ms"])
    assert is_integer(timings_ms["loop_ms"])
    assert is_integer(timings_ms["evidence_replan_ms"])
    assert is_integer(timings_ms["prompt_fit_ms"])
    assert is_integer(timings_ms["synthesize_ms"])
    assert is_integer(timings_ms["rewrite_ms"])
    assert is_integer(timings_ms["structured_output_ms"])
    assert is_integer(timings_ms["total_ms"])
    assert reflect_ms >= timings_ms["total_ms"]
    assert put_bank_ms >= 0
    assert retain_ms >= 0
    assert recall_ms >= 0
  end

  test "shared recall frontier stays top-1 across the real ML stack" do
    bank_id = "full-ml-recall-" <> Integer.to_string(System.system_time(:millisecond))
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    {_bank, _put_bank_ms} =
      timed_ok!("put_bank", 30_000, fn ->
        Foresight.put_bank(ctx, bank_id, %{
          "name" => "Full ML Recall Frontier Bank",
          "mission" =>
            "Retrieve the correct diary memory across contradiction and schedule distractors."
        })
      end)

    corpus = RecallQuality.corpus()

    {%{"success" => true, "items_count" => item_count}, _retain_ms} =
      timed_ok!("retain", 420_000, fn ->
        Foresight.retain(ctx, %{
          "async" => false,
          "items" => corpus
        })
      end)

    assert item_count == length(corpus)

    for scenario <- selected_recall_scenarios() do
      {%{"results" => results, "trace" => trace}, _recall_ms} =
        timed_ok!("recall:#{scenario.id}", 180_000, fn ->
          Foresight.recall(ctx, %{
            "query" => scenario.query,
            "query_timestamp" => scenario.query_timestamp,
            "trace" => true,
            "budget" => "mid",
            "max_tokens" => 512
          })
        end)

      top_texts = Enum.map(results, & &1["text"])
      hit_index = Enum.find_index(top_texts, &RecallQuality.matches_text?(scenario, &1))

      assert hit_index == 0,
             recall_failure_message(scenario, results, trace)

      assert trace["reranker"]["active"] == true
      assert trace["reranker"]["count"] >= 1
    end
  end

  test "reflect stays grounded across the correction frontier on the shared diary corpus" do
    bank_id = "reflect-quality-" <> Integer.to_string(System.system_time(:millisecond))
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    {_bank, _put_bank_ms} =
      timed_ok!("put_bank", 30_000, fn ->
        Foresight.put_bank(ctx, bank_id, %{
          "name" => "Reflect Quality Bank",
          "mission" => "Stay grounded on correction, temporal ordering, and cutover posture."
        })
      end)

    corpus = RecallQuality.reflect_corpus()

    {%{"success" => true, "items_count" => item_count}, _retain_ms} =
      timed_ok!("retain", 420_000, fn ->
        Foresight.retain(ctx, %{
          "async" => false,
          "items" => corpus
        })
      end)

    assert item_count == length(corpus)

    schema = %{
      "title" => "reflect_quality_eval",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["summary", "grounded"],
      "properties" => %{
        "summary" => %{"type" => "string"},
        "grounded" => %{"type" => "boolean"}
      }
    }

    for scenario <- RecallQuality.reflect_scenarios() do
      {%{
         "text" => text,
         "memory_ids" => memory_ids,
         "based_on" => %{"memories" => grounded_memories},
         "structured_output" => %{"summary" => summary},
         "trace" => %{"llm_calls" => llm_calls, "timings_ms" => timings_ms}
       }, _reflect_ms} =
        timed_ok!("reflect:#{scenario.id}", 420_000, fn ->
          Foresight.reflect(
            ctx,
            %{
              "query" => scenario.query,
              "query_timestamp" => scenario.query_timestamp,
              "trace" => true,
              "response_schema" => schema
            },
            reflect_timeout_ms: 420_000
          )
        end)

      refute String.contains?(String.downcase(text), "i don't have enough grounded information"),
             "scenario=#{scenario.id} returned fail-closed fallback text"

      assert RecallQuality.matches_reflect_text?(scenario, text),
             "scenario=#{scenario.id} text mismatch: #{inspect(text)}"

      assert RecallQuality.matches_reflect_text?(scenario, summary),
             "scenario=#{scenario.id} summary mismatch: #{inspect(summary)}"

      required_memory_texts = RecallQuality.required_memory_texts(scenario)
      grounded_texts = Enum.map(grounded_memories, & &1["text"])

      assert required_memory_texts == [] or
               Enum.any?(grounded_memories, fn memory ->
                 memory["text"] in required_memory_texts
               end),
             "scenario=#{scenario.id} missing required grounding memories: expected one of #{inspect(required_memory_texts)} got #{inspect(grounded_texts)}"

      assert memory_ids != []

      assert Enum.map(llm_calls, & &1["phase"]) == ["plan", "synthesize", "structured_output"]
      assert is_integer(timings_ms["recall_ms"])
      assert is_integer(timings_ms["structured_output_ms"])
    end
  end

  test "reflect frontier stays grounded across repeated real ML rounds" do
    rounds = reflect_soak_rounds()
    schema = reflect_quality_schema()

    for round <- 1..rounds do
      bank_id = "reflect-soak-#{round}-" <> Integer.to_string(System.system_time(:millisecond))
      ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

      {_bank, _put_bank_ms} =
        timed_ok!("put_bank:round#{round}", 30_000, fn ->
          Foresight.put_bank(ctx, bank_id, %{
            "name" => "Reflect Soak Round #{round}",
            "mission" =>
              "Stay grounded across repeated diary-style qualification rounds under the real ML stack."
          })
        end)

      corpus = RecallQuality.reflect_corpus()

      {%{"success" => true, "items_count" => item_count}, _retain_ms} =
        timed_ok!("retain:round#{round}", 420_000, fn ->
          Foresight.retain(ctx, %{
            "async" => false,
            "items" => corpus
          })
        end)

      assert item_count == length(corpus)

      for scenario <- selected_reflect_scenarios() do
        {%{
           "text" => text,
           "memory_ids" => memory_ids,
           "based_on" => %{"memories" => grounded_memories},
           "structured_output" => %{"summary" => summary},
           "trace" => %{
             "llm_calls" => llm_calls,
             "timings_ms" => timings_ms,
             "grounding_validation" => grounding_validation
           }
         }, _reflect_ms} =
          timed_ok!("reflect:round#{round}:#{scenario.id}", 420_000, fn ->
            Foresight.reflect(
              ctx,
              %{
                "query" => scenario.query,
                "query_timestamp" => scenario.query_timestamp,
                "trace" => true,
                "response_schema" => schema
              },
              reflect_timeout_ms: 420_000
            )
          end)

        assert RecallQuality.matches_reflect_text?(scenario, text),
               "round=#{round} scenario=#{scenario.id} text mismatch: #{inspect(text)}"

        assert RecallQuality.matches_reflect_text?(scenario, summary),
               "round=#{round} scenario=#{scenario.id} summary mismatch: #{inspect(summary)}"

        required_memory_texts = RecallQuality.required_memory_texts(scenario)
        grounded_texts = Enum.map(grounded_memories, & &1["text"])

        assert required_memory_texts == [] or
                 Enum.any?(grounded_memories, fn memory ->
                   memory["text"] in required_memory_texts
                 end),
               "round=#{round} scenario=#{scenario.id} missing required grounding memories: expected one of #{inspect(required_memory_texts)} got #{inspect(grounded_texts)}"

        assert memory_ids != []
        assert grounding_validation["used_memory_ids"] != []
        assert Enum.map(llm_calls, & &1["phase"]) == ["plan", "synthesize", "structured_output"]
        assert is_integer(timings_ms["recall_ms"])
        assert is_integer(timings_ms["structured_output_ms"])
      end
    end
  end

  defp llm_endpoint_available? do
    case Req.get(llm_models_endpoint(), receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> true
      _other -> false
    end
  end

  defp llm_model! do
    case Req.get(llm_models_endpoint(), receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status, body: %{"data" => [%{"id" => model} | _]}}}
      when status in 200..299 and is_binary(model) and model != "" ->
        model

      {:ok, %Req.Response{status: status, body: %{"models" => [%{"name" => model} | _]}}}
      when status in 200..299 and is_binary(model) and model != "" ->
        model

      other ->
        raise "Unable to discover a model from #{llm_models_endpoint()}: #{inspect(other)}"
    end
  end

  defp llm_provider do
    System.get_env("FORESIGHT_LLM_PROVIDER") || default_llm_provider(llm_base_url())
  end

  defp llm_base_url do
    System.get_env("FORESIGHT_LLM_BASE_URL") ||
      System.get_env("LMSTUDIO_BASE_URL") ||
      "http://127.0.0.1:1234/v1"
  end

  defp llm_api_key do
    System.get_env("FORESIGHT_LLM_API_KEY") ||
      System.get_env("LMSTUDIO_API_KEY") ||
      "lm-studio"
  end

  defp llm_models_endpoint do
    base_url = normalize_base_url(llm_base_url())

    if llm_provider() == "ollama" do
      base_url <> "/api/tags"
    else
      base_url <> "/models"
    end
  end

  defp default_llm_provider(base_url) when is_binary(base_url) do
    if String.contains?(base_url, ":11434"), do: "ollama", else: "openai"
  end

  defp default_llm_provider(_base_url), do: "openai"

  defp normalize_base_url(base_url) when is_binary(base_url) do
    String.trim_trailing(base_url, "/")
  end

  defp local_ml_backend do
    System.get_env("FORESIGHT_LOCAL_ML_BACKEND") || "sentence_transformers"
  end

  defp maybe_put_sentence_transformers_python(env) do
    if env["FORESIGHT_LOCAL_ML_BACKEND"] == "sentence_transformers" do
      case sentence_transformers_python() do
        nil -> env
        python -> Map.put_new(env, "FORESIGHT_ML_PYTHON", python)
      end
    else
      env
    end
  end

  defp sentence_transformers_python do
    env_python = System.get_env("FORESIGHT_ML_PYTHON")
    default_python = System.find_executable("python3") || "python3"

    cond do
      is_binary(env_python) and File.exists?(env_python) -> env_python
      File.exists?(default_python) -> default_python
      true -> nil
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp maybe_start_bumblebee_servings!(profile) do
    if profile.engine_config.embedder == Foresight.Embedders.Bumblebee do
      start_supervised!(
        {Foresight.ML.Serving,
         name: @embedding_serving_name,
         model_id: profile.resolved_config.ml.model_id,
         output_attribute: profile.resolved_config.ml.output_attribute,
         output_pool: profile.resolved_config.ml.output_pool,
         embedding_processor: profile.resolved_config.ml.embedding_processor,
         batch_size: profile.resolved_config.ml.batch_size,
         sequence_length: profile.resolved_config.ml.sequence_length}
      )

      start_supervised!(
        {Foresight.ML.RerankerServing,
         name: @reranker_serving_name,
         model_id: profile.resolved_config.ml.reranker_model_id,
         batch_size: profile.resolved_config.ml.reranker_batch_size,
         sequence_length: profile.resolved_config.ml.reranker_sequence_length}
      )
    end
  end

  defp maybe_put_bumblebee_serving_names(ml_config) do
    if Keyword.get(ml_config, :enabled) do
      ml_config
      |> Keyword.put(:serving_name, @embedding_serving_name)
      |> Keyword.put(:reranker_serving_name, @reranker_serving_name)
    else
      ml_config
    end
  end

  defp maybe_put_bumblebee_reranker_serving_name(engine_config, profile) do
    if profile.engine_config.reranker == Foresight.Rerankers.Bumblebee do
      Keyword.put(engine_config, :reranker_serving_name, @reranker_serving_name)
    else
      engine_config
    end
  end

  defp warm_local_ml_path!(embedder, reranker, ml_config) do
    embedder_opts =
      ml_config
      |> Keyword.take([
        :serving_name,
        :python_worker_name,
        :python_executable,
        :python_path,
        :model_id,
        :batch_size,
        :sequence_length,
        :force_cpu,
        :trust_remote_code
      ])

    reranker_opts =
      ml_config
      |> Keyword.take([
        :reranker_serving_name,
        :python_worker_name,
        :python_executable,
        :python_path,
        :reranker_model_id,
        :reranker_batch_size,
        :reranker_sequence_length,
        :force_cpu,
        :trust_remote_code
      ])

    assert {:ok, embedding} = embedder.embed("foresight warmup", embedder_opts)
    assert length(embedding) == 384

    assert {:ok, [_candidate]} =
             reranker.rerank(
               "foresight warmup",
               [%{"id" => "warmup", "content" => "foresight warmup", "rrf_score" => 0.0}],
               reranker_opts
             )
  end

  defp warm_llm_reflect_path! do
    query = "What did Alice and I decide about the Foresight cutover after Oxford?"

    plan_prompt =
      Foresight.Prompts.Reflect.Plan.V1.build(
        query,
        %{"budget" => "low"},
        bank_profile(),
        recalled_results(),
        observations(),
        [],
        []
      )

    assert {:ok, %ReflectPlanResponse{}} =
             LlmCore.complete_structured(plan_prompt, [], ReflectPlanResponse, [])

    reflect_prompt =
      Foresight.Prompts.Reflect.V1.build(
        query,
        %{"budget" => "low"},
        bank_profile(),
        recalled_results(),
        observations(),
        [],
        [],
        %{
          reason: "planner marked the current evidence sufficient",
          answer_ready: true,
          needs_consolidation: false,
          max_iterations: 1
        }
      )

    assert {:ok, %ReflectResponse{}} =
             LlmCore.complete_structured(reflect_prompt, [], ReflectResponse, [])
  end

  defp timed_ok!(label, timeout_ms, fun)
       when is_binary(label) and is_integer(timeout_ms) and timeout_ms > 0 and
              is_function(fun, 0) do
    {result, elapsed_ms} = timed_call(timeout_ms, fun)

    case result do
      {:ok, value} -> {value, elapsed_ms}
      {:timeout, exceeded_ms} -> flunk("#{label} timed out after #{exceeded_ms}ms")
      {:error, reason} -> flunk("#{label} failed after #{elapsed_ms}ms: #{inspect(reason)}")
    end
  end

  defp timed_call(timeout_ms, fun) when is_integer(timeout_ms) and is_function(fun, 0) do
    started_at_ms = System.monotonic_time(:millisecond)

    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {result, System.monotonic_time(:millisecond) - started_at_ms}

      nil ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
        {{:timeout, elapsed_ms}, elapsed_ms}
    end
  end

  defp bank_profile do
    %{
      "bank_id" => "diary-ml-bank",
      "name" => "Diary ML Bank",
      "mission" => "Remember diary facts faithfully and avoid invention.",
      "disposition" => %{"skepticism" => 7, "empathy" => 6}
    }
  end

  defp recalled_results do
    [
      %{
        "id" => "mem-1",
        "text" =>
          "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven.",
        "type" => "world",
        "score" => 0.99,
        "tags" => ["diary", "project:foresight", "person:alice", "place:oxford"]
      }
    ]
  end

  defp observations do
    %{
      "count" => 0,
      "freshness" => "unknown",
      "is_stale" => false,
      "observations" => []
    }
  end

  defp topic_match?(text, terms) when is_binary(text) do
    normalized = String.downcase(text)
    Enum.any?(terms, &String.contains?(normalized, &1))
  end

  defp recall_failure_message(scenario, results, trace) do
    """
    scenario=#{scenario.id} expected top1 in #{inspect(RecallQuality.acceptable_texts(scenario))} got #{inspect(Enum.take(Enum.map(results, & &1["text"]), 3))}
    trace summary: #{inspect(trace_summary(trace), pretty: true, limit: :infinity)}
    """
  end

  defp trace_summary(trace) do
    expected_match =
      fn entry ->
        case Map.get(entry, "text") do
          text when is_binary(text) ->
            RecallQuality.matches_text?(scenario_from_trace(trace), text)

          _ ->
            false
        end
      end

    %{
      "rrf" => stage_summary(Map.get(trace, "rrf_merged", []), expected_match),
      "rerank_candidates" =>
        stage_summary(Map.get(trace, "rerank_candidates", []), expected_match),
      "reranked" => stage_summary(Map.get(trace, "reranked", []), expected_match),
      "boosted" => stage_summary(Map.get(trace, "boosted", []), expected_match),
      "final_results" => stage_summary(Map.get(trace, "final_results", []), expected_match),
      "displacement" => Map.get(trace, "displacement"),
      "summary" => Map.get(trace, "summary")
    }
  end

  defp scenario_from_trace(%{"query" => query}) do
    Enum.find(RecallQuality.scenarios(), fn scenario -> scenario.query == query end) || %{}
  end

  defp scenario_from_trace(_trace), do: %{}

  defp stage_summary(entries, matcher) when is_list(entries) do
    %{
      "top" => Enum.take(Enum.map(entries, &entry_summary/1), 5),
      "expected" =>
        entries
        |> Enum.find(matcher)
        |> case do
          nil -> nil
          entry -> entry_summary(entry)
        end,
      "all_expected" =>
        entries
        |> Enum.filter(matcher)
        |> Enum.map(&entry_summary/1)
    }
  end

  defp entry_summary(entry) when is_map(entry) do
    %{
      "rank" => entry["rank"],
      "score" => entry["score"],
      "node_id" => entry["node_id"],
      "text" => entry["text"],
      "movement" => entry["movement"],
      "boosts" =>
        Map.take(Map.get(entry, "boosts", %{}), [
          "recency_contribution",
          "temporal_contribution",
          "proof_contribution",
          "source_expansion_contribution",
          "source_novel_only_contribution",
          "revision_status_contribution",
          "memory_breadth_contribution"
        ]),
      "fusion" => Map.take(Map.get(entry, "fusion", %{}), ["winning_strategy", "strategy_count"])
    }
  end

  defp selected_recall_scenarios do
    case System.get_env("FORESIGHT_RECALL_SCENARIO_IDS") do
      nil ->
        RecallQuality.scenarios()

      ids ->
        selected_ids =
          ids
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> MapSet.new()

        Enum.filter(RecallQuality.scenarios(), &MapSet.member?(selected_ids, &1.id))
    end
  end

  defp selected_reflect_scenarios do
    case System.get_env("FORESIGHT_REFLECT_SCENARIO_IDS") do
      nil ->
        RecallQuality.reflect_scenarios()

      ids ->
        selected_ids =
          ids
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> MapSet.new()

        Enum.filter(RecallQuality.reflect_scenarios(), &MapSet.member?(selected_ids, &1.id))
    end
  end

  defp reflect_quality_schema do
    %{
      "title" => "reflect_quality_eval",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["summary", "grounded"],
      "properties" => %{
        "summary" => %{"type" => "string"},
        "grounded" => %{"type" => "boolean"}
      }
    }
  end

  defp reflect_soak_rounds do
    case System.get_env("FORESIGHT_REFLECT_SOAK_ROUNDS") do
      nil ->
        3

      value ->
        case Integer.parse(value) do
          {rounds, ""} when rounds > 0 -> rounds
          _ -> 3
        end
    end
  end
end
