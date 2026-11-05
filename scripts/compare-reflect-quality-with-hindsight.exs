defmodule Foresight.CompareReflectQualityWithHindsightScript do
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Error, as: ForesightError
  alias Foresight.Evals.RecallQuality
  alias Foresight.Profiles.FullMLAuthority
  alias LlmCore.LLM.Error, as: LlmError
  require Logger

  @default_bank_id "reflect-quality-compare"

  def run do
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    Logger.configure(level: :info)

    foresight_profile = FullMLAuthority.build(full_ml_env())
    hindsight_client = hindsight_client()
    bank_id = compare_bank_id()

    ensure_database(foresight_profile.database_url)
    configure_foresight(foresight_profile)
    migrate!(foresight_profile)
    start_supervisor!(foresight_profile)

    foresight_ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}
    corpus = RecallQuality.reflect_corpus()
    scenarios = RecallQuality.reflect_scenarios()

    seed_foresight!(foresight_ctx, bank_id, corpus)
    seed_hindsight!(hindsight_client, bank_id, corpus)

    IO.puts("Comparing reflect quality against live Hindsight...")
    IO.puts("  foresight_backend: #{System.get_env("FORESIGHT_LOCAL_ML_BACKEND", "bumblebee")}")
    IO.puts("  hindsight_base_url: #{hindsight_client.base_url}")
    IO.puts("  bank: #{bank_id}")
    IO.puts("  corpus_size: #{length(corpus)}")
    IO.puts("  scenarios: #{length(scenarios)}")
    IO.puts("")

    results =
      Enum.map(scenarios, fn scenario ->
        foresight = evaluate_foresight_scenario(foresight_ctx, scenario)
        hindsight = evaluate_hindsight_scenario(hindsight_client, bank_id, scenario)

        IO.puts(
          "#{scenario.id} [#{scenario.class}] foresight=#{render_score(foresight)} hindsight=#{render_score(hindsight)}"
        )

        maybe_print_delta(scenario, foresight, hindsight)

        %{
          id: scenario.id,
          class: scenario.class,
          foresight: foresight,
          hindsight: hindsight
        }
      end)

    print_summary(results)
  end

  defp evaluate_foresight_scenario(ctx, scenario) do
    payload =
      %{
        "query" => scenario.query,
        "trace" => true,
        "response_schema" => reflect_quality_schema()
      }
      |> maybe_put_query_timestamp(scenario.query_timestamp)

    case timed(fn -> Foresight.reflect(ctx, payload) end) do
      {result, elapsed_ms} ->
        case unwrap_operation_result(result) do
          {:ok, response} -> build_outcome(response, elapsed_ms, scenario)
          {:error, reason} -> build_error_outcome(reason, elapsed_ms)
        end
    end
  end

  defp evaluate_hindsight_scenario(client, bank_id, scenario) do
    path = "/v1/default/banks/#{bank_id}/reflect"

    payload =
      %{
        "query" => scenario.query,
        "include" => %{
          "facts" => %{},
          "tool_calls" => %{"output" => false}
        },
        "response_schema" => reflect_quality_schema()
      }
      |> maybe_put_query_timestamp(scenario.query_timestamp)

    case timed(fn -> request_json(client, :post, path, payload) end) do
      {result, elapsed_ms} ->
        case unwrap_operation_result(result) do
          {:ok, response} -> build_outcome(response, elapsed_ms, scenario)
          {:error, reason} -> build_error_outcome(reason, elapsed_ms)
        end
    end
  end

  defp build_outcome(response, elapsed_ms, scenario) do
    text = Map.get(response, "text", "")
    summary = get_in(response, ["structured_output", "summary"]) || ""
    grounded_memories = get_in(response, ["based_on", "memories"]) || []
    grounded_texts = Enum.map(grounded_memories, &Map.get(&1, "text"))
    required_memory_texts = RecallQuality.required_memory_texts(scenario)

    text_match? = RecallQuality.matches_reflect_text?(scenario, text)
    summary_match? = is_binary(summary) and RecallQuality.matches_reflect_text?(scenario, summary)

    required_memory_present? =
      required_memory_texts == [] or
        Enum.any?(grounded_texts, &(&1 in required_memory_texts))

    %{
      text_match?: text_match?,
      summary_match?: summary_match?,
      required_memory_present?: required_memory_present?,
      error?: false,
      grounded_memory_count: length(grounded_memories),
      elapsed_ms: elapsed_ms,
      text: text,
      summary: summary,
      grounded_texts: Enum.take(grounded_texts, 5),
      llm_call_count: llm_call_count(response),
      error_detail: nil
    }
  end

  defp build_error_outcome(reason, elapsed_ms) do
    %{
      text_match?: false,
      summary_match?: false,
      required_memory_present?: false,
      error?: true,
      grounded_memory_count: 0,
      elapsed_ms: elapsed_ms,
      text: "",
      summary: "",
      grounded_texts: [],
      llm_call_count: 0,
      error_detail: error_detail(reason)
    }
  end

  defp maybe_print_delta(scenario, foresight, hindsight) do
    if comparable_score(foresight) != comparable_score(hindsight) do
      IO.puts("  query: #{scenario.query}")
      IO.puts("  foresight: #{inspect(delta_view(foresight))}")
      IO.puts("  hindsight: #{inspect(delta_view(hindsight))}")
    end
  end

  defp delta_view(result) do
    %{
      score: render_score(result),
      elapsed_ms: result.elapsed_ms,
      llm_call_count: result.llm_call_count,
      error: result.error_detail,
      text: result.text,
      summary: result.summary,
      grounded_texts: result.grounded_texts
    }
  end

  defp print_summary(results) do
    foresight_wins =
      Enum.count(results, fn %{foresight: foresight, hindsight: hindsight} ->
        comparable_score(foresight) > comparable_score(hindsight)
      end)

    hindsight_wins =
      Enum.count(results, fn %{foresight: foresight, hindsight: hindsight} ->
        comparable_score(hindsight) > comparable_score(foresight)
      end)

    ties = length(results) - foresight_wins - hindsight_wins

    IO.puts("")
    IO.puts("Summary")
    IO.puts("  foresight_perfect: #{perfect_count(results, :foresight)}/#{length(results)}")
    IO.puts("  hindsight_perfect: #{perfect_count(results, :hindsight)}/#{length(results)}")
    IO.puts("  foresight_wins: #{foresight_wins}")
    IO.puts("  hindsight_wins: #{hindsight_wins}")
    IO.puts("  ties: #{ties}")
    IO.puts("  foresight_avg_ms: #{average_ms(Enum.map(results, & &1.foresight.elapsed_ms))}")
    IO.puts("  hindsight_avg_ms: #{average_ms(Enum.map(results, & &1.hindsight.elapsed_ms))}")
  end

  defp perfect_count(results, side) do
    Enum.count(results, fn result ->
      outcome = Map.fetch!(result, side)
      comparable_score(outcome) == 3
    end)
  end

  defp comparable_score(result) do
    [
      result.text_match?,
      result.summary_match?,
      result.required_memory_present?
    ]
    |> Enum.count(& &1)
  end

  defp render_score(result), do: "#{comparable_score(result)}/3"

  defp average_ms([]), do: 0
  defp average_ms(values), do: round(Enum.sum(values) / length(values))

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

  defp llm_call_count(%{"trace" => %{"llm_calls" => llm_calls}}) when is_list(llm_calls),
    do: length(llm_calls)

  defp llm_call_count(_response), do: 0

  defp unwrap_operation_result({inner, elapsed_ms}) when is_integer(elapsed_ms),
    do: unwrap_operation_result(inner)

  defp unwrap_operation_result(result), do: result

  defp error_detail(%LlmError{} = error) do
    %{
      type: error.type,
      message: error.message,
      provider: error.provider,
      details: error.details
    }
  end

  defp error_detail(%ForesightError{} = error) do
    %{
      type: error.reason,
      detail: error.detail
    }
  end

  defp error_detail(%{status: status, body: body}) do
    %{
      status: status,
      body: body
    }
  end

  defp error_detail(reason), do: inspect(reason)

  defp seed_foresight!(ctx, bank_id, corpus) do
    {:ok, _} =
      Foresight.put_bank(ctx, bank_id, %{
        "name" => "Reflect Quality Compare",
        "mission" => "Compare reflect behavior with live Hindsight."
      })

    {:ok, %{"items_count" => count}} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => corpus
      })

    IO.puts("Seeded Foresight with #{count} items")
  end

  defp seed_hindsight!(client, bank_id, corpus) do
    bank_path = "/v1/default/banks/#{bank_id}"

    _ = request_json(client, :delete, bank_path, nil)

    _ =
      request_json!(client, :put, bank_path, %{
        "name" => "Reflect Quality Compare",
        "mission" => "Compare reflect behavior with Foresight."
      })

    %{"items_count" => count} =
      request_json!(client, :post, bank_path <> "/memories", %{
        "items" => corpus,
        "async" => false
      })

    IO.puts("Seeded Hindsight with #{count} items")
  end

  defp maybe_put_query_timestamp(payload, nil), do: payload

  defp maybe_put_query_timestamp(payload, timestamp),
    do: Map.put(payload, "query_timestamp", timestamp)

  defp compare_bank_id do
    System.get_env("FORESIGHT_COMPARE_BANK_ID", @default_bank_id)
  end

  defp hindsight_client do
    %{
      base_url:
        System.get_env("HINDSIGHT_FIXTURE_BASE_URL", "http://127.0.0.1:8888")
        |> String.trim_trailing("/"),
      api_key: System.get_env("HINDSIGHT_FIXTURE_API_KEY", "sk-foresight-fixtures-dev")
    }
  end

  defp full_ml_env do
    %{
      "FORESIGHT_LOCAL_ML_BACKEND" => local_ml_backend(),
      "FORESIGHT_LLM_PROVIDER" => llm_provider(),
      "FORESIGHT_LLM_BASE_URL" => llm_base_url(),
      "FORESIGHT_LLM_API_KEY" => llm_api_key(),
      "FORESIGHT_LLM_MODEL" => llm_model!()
    }
    |> maybe_put_sentence_transformers_python()
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
    case System.get_env("FORESIGHT_ML_PYTHON") do
      nil -> System.find_executable("python3")
      path -> if File.exists?(path), do: path
    end
  end

  defp configure_foresight(profile) do
    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    Application.put_env(:foresight, :auth, profile.resolved_config.auth)
    Application.put_env(:foresight, :engine, profile.engine_config)
    Application.put_env(:foresight, :file_ingestion, profile.resolved_config.file_ingestion)
    Application.put_env(:foresight, :health, profile.resolved_config.health)
    Application.put_env(:foresight, :http, profile.resolved_config.http)
    Application.put_env(:foresight, :mcp, profile.resolved_config.mcp)
    Application.put_env(:foresight, :ml, profile.resolved_config.ml)
    Application.put_env(:foresight, :oban, profile.resolved_config.oban)
    Application.put_env(:foresight, :repo, profile.resolved_config.repo)
    Application.put_env(:foresight, :tenancy, profile.resolved_config.tenancy)
    Application.put_env(:foresight, :tokenizer, profile.resolved_config.tokenizer)
    Application.put_env(:foresight, :webhook_delivery, profile.resolved_config.webhook_delivery)

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(Foresight.Repo.config(), profile.repo_start_opts)
    )

    Application.put_env(
      :foresight,
      Foresight.PublicRepo,
      Keyword.merge(Foresight.PublicRepo.config(), profile.public_repo_start_opts)
    )
  end

  defp ensure_database(database_url) do
    db_uri = URI.parse(database_url)
    db_name = db_uri |> Map.fetch!(:path) |> String.trim_leading("/")
    admin_url = %{db_uri | path: "/postgres"} |> URI.to_string()

    with true <- executable_available?("psql"),
         false <- database_available?(database_url),
         {_, 0} <-
           System.cmd(
             "psql",
             [admin_url, "-v", "ON_ERROR_STOP=1", "-c", "CREATE DATABASE #{db_name}"],
             stderr_to_stdout: true
           ) do
      IO.puts("Created scratch Postgres database: #{db_name}")
    else
      true -> :ok
      false -> :ok
      {_output, 0} -> :ok
      {output, exit_code} -> raise "database creation failed (#{exit_code}): #{output}"
    end
  end

  defp migrate!(profile) do
    migrations_path = Path.expand("../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    IO.puts("Database migrated for #{profile.database_url}")
  end

  defp start_supervisor!(profile) do
    {:ok, _pid} =
      Foresight.Supervisor.start_link(Keyword.put(profile.opts, :name, profile.supervisor_name))
  end

  defp request_json!(client, method, path, body) do
    case request_json(client, method, path, body) do
      {:ok, response} ->
        response

      {:error, reason} ->
        raise "Hindsight request failed for #{method} #{path}: #{inspect(reason)}"
    end
  end

  defp request_json(client, method, path, body) do
    url = client.base_url <> path
    headers = request_headers(client)

    response =
      case body do
        nil ->
          :httpc.request(method, {to_charlist(url), headers}, http_options(),
            body_format: :binary
          )

        payload ->
          encoded = Jason.encode!(payload)

          :httpc.request(
            method,
            {to_charlist(url), headers, ~c"application/json", encoded},
            http_options(),
            body_format: :binary
          )
      end

    case response do
      {:ok, {{_http_version, status, _reason_phrase}, _headers, raw_body}}
      when status in 200..299 ->
        {:ok, Jason.decode!(raw_body)}

      {:ok, {{_http_version, status, _reason_phrase}, _headers, raw_body}} ->
        {:error, %{status: status, body: raw_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_headers(client) do
    [
      {~c"accept", ~c"application/json"},
      {~c"content-type", ~c"application/json"},
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(client.api_key)}
    ]
  end

  defp http_options do
    [timeout: 120_000, connect_timeout: 30_000]
  end

  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    finished_at = System.monotonic_time(:millisecond)
    {result, finished_at - started_at}
  end

  defp executable_available?(name) do
    match?({_path, 0}, System.cmd("sh", ["-lc", "command -v #{name}"], stderr_to_stdout: true))
  end

  defp database_available?(database_url) do
    match?(
      {_output, 0},
      System.cmd("psql", [database_url, "-c", "select 1"], stderr_to_stdout: true)
    )
  end
end

IO.puts(:stderr, """
⚠️  WARNING: grades with Foresight.Evals.RecallQuality — a QUARANTINED phrase-matching
    metric (corpus-phrase echo, NOT reflect quality). Do NOT cite its numbers as a
    quality baseline. Authoritative measure: the LongMemEval harness (Foresight.Evals.Runner).
""")

Foresight.CompareReflectQualityWithHindsightScript.run()
