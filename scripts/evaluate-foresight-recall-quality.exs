defmodule Foresight.RecallQualityEvalScript do
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.RecallQuality
  alias Foresight.Profiles.FullMLAuthority
  require Logger

  @windows [:adaptive, 20, 40, 80]

  def run do
    Logger.configure(level: :info)
    profile = FullMLAuthority.build()

    ensure_database(profile.database_url)
    configure_application(profile)
    migrate!(profile)
    start_supervisor!(profile)

    bank_id = "quality-" <> Integer.to_string(System.system_time(:millisecond))
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}
    corpus = RecallQuality.corpus()
    scenarios = RecallQuality.scenarios()
    windows = parse_windows()

    {:ok, _bank} =
      Foresight.put_bank(ctx, bank_id, %{
        "name" => "Recall Quality Eval Bank",
        "mission" => "Surface the correct memory under semantically-near distractors."
      })

    IO.puts("Evaluating Foresight recall quality...")
    IO.puts("  backend: #{System.get_env("FORESIGHT_LOCAL_ML_BACKEND", "bumblebee")}")
    IO.puts("  bank: #{bank_id}")
    IO.puts("  corpus_size: #{length(corpus)}")
    IO.puts("  scenarios: #{length(scenarios)}")
    IO.puts("  windows: #{Enum.map_join(windows, ", ", &window_label/1)}")
    IO.puts("")

    {retain_result, retain_ms} =
      timed(fn ->
        Foresight.retain(ctx, %{
          "async" => false,
          "items" => corpus
        })
      end)

    {:ok, %{"items_count" => retained_count}} = retain_result
    IO.puts("Retained #{retained_count} items in #{retain_ms}ms")
    IO.puts("")

    windows
    |> Enum.each(fn window ->
      apply_window(ctx, window)
      evaluate_window(ctx, window, scenarios)
      IO.puts("")
    end)
  end

  defp evaluate_window(ctx, window, scenarios) do
    IO.puts("Window #{window_label(window)}")

    scenario_results =
      Enum.map(scenarios, fn scenario ->
        payload = %{
          "query" => scenario.query,
          "trace" => true,
          "budget" => "mid",
          "max_tokens" => 512
        }

        payload =
          case scenario.query_timestamp do
            nil -> payload
            query_timestamp -> Map.put(payload, "query_timestamp", query_timestamp)
          end

        {{:ok, response}, recall_ms} = timed(fn -> Foresight.recall(ctx, payload) end)

        results = Map.get(response, "results", [])
        top_texts = Enum.map(results, & &1["text"])
        acceptable_texts = RecallQuality.acceptable_texts(scenario)
        position = Enum.find_index(top_texts, &RecallQuality.matches_text?(scenario, &1))
        hit_rank = if is_nil(position), do: nil, else: position + 1
        hit_top_3? = hit_rank != nil and hit_rank <= 3
        recall_trace = get_in(response, ["trace", "timings_ms"]) || %{}

        IO.puts(
          "  #{scenario.id} [#{scenario.class}]: hit_rank=#{inspect(hit_rank)} top3=#{hit_top_3?} recall_ms=#{recall_ms} rerank_ms=#{Map.get(recall_trace, "rerank_ms")}"
        )

        IO.puts("    expected: #{scenario.expected_text}")

        top_texts
        |> Enum.take(3)
        |> Enum.with_index(1)
        |> Enum.each(fn {text, rank} ->
          IO.puts("    top#{rank}: #{text}")
        end)

        %{
          id: scenario.id,
          class: scenario.class,
          hit_rank: hit_rank,
          hit_top_3?: hit_top_3?,
          recall_ms: recall_ms,
          rerank_ms: Map.get(recall_trace, "rerank_ms", 0),
          ranked_recall_ms: Map.get(recall_trace, "ranked_recall_ms", 0)
        }
      end)

    summary = summarize_results(scenario_results)

    IO.puts(
      "  summary: top1=#{summary.top1_hits}/#{summary.total} top3=#{summary.top3_hits}/#{summary.total} avg_recall_ms=#{summary.avg_recall_ms} avg_rerank_ms=#{summary.avg_rerank_ms}"
    )

    summary.by_class
    |> Enum.each(fn {class, class_summary} ->
      IO.puts(
        "    class #{class}: top1=#{class_summary.top1_hits}/#{class_summary.total} top3=#{class_summary.top3_hits}/#{class_summary.total}"
      )
    end)
  end

  defp summarize_results(results) do
    total = length(results)

    %{
      total: total,
      top1_hits: Enum.count(results, &(&1.hit_rank == 1)),
      top3_hits: Enum.count(results, & &1.hit_top_3?),
      avg_recall_ms: average_ms(results, :recall_ms),
      avg_rerank_ms: average_ms(results, :rerank_ms),
      by_class: summarize_by_class(results)
    }
  end

  defp summarize_by_class(results) do
    results
    |> Enum.group_by(& &1.class)
    |> Enum.sort_by(fn {class, _results} -> class end)
    |> Enum.map(fn {class, grouped_results} ->
      {class,
       %{
         total: length(grouped_results),
         top1_hits: Enum.count(grouped_results, &(&1.hit_rank == 1)),
         top3_hits: Enum.count(grouped_results, & &1.hit_top_3?)
       }}
    end)
  end

  defp average_ms(results, key) do
    results
    |> Enum.map(&Map.get(&1, key, 0))
    |> case do
      [] -> 0
      values -> round(Enum.sum(values) / length(values))
    end
  end

  defp apply_window(ctx, :adaptive) do
    {:ok, _response} =
      Foresight.reset_bank_config(ctx, ctx.bank)

    :ok
  end

  defp apply_window(ctx, window) when is_integer(window) and window > 0 do
    {:ok, _response} =
      Foresight.update_bank_config(ctx, ctx.bank, %{
        "HINDSIGHT_API_RECALL_RERANK_WINDOW" => window
      })

    :ok
  end

  defp parse_windows do
    case System.get_env("FORESIGHT_EVAL_WINDOWS") do
      nil ->
        @windows

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn
          "adaptive" -> :adaptive
          item -> String.to_integer(item)
        end)
    end
  end

  defp window_label(:adaptive), do: "adaptive"
  defp window_label(window), do: Integer.to_string(window)

  defp configure_application(profile) do
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
⚠️  WARNING: this script grades with Foresight.Evals.RecallQuality — a QUARANTINED
    phrase-matching metric that measures corpus-phrase echo, NOT retrieval quality.
    Its top1/top3 numbers MUST NOT be cited as a quality baseline. The authoritative
    recall-quality measure is the LongMemEval harness (Foresight.Evals.Runner over
    RankingMetrics). This script remains only as a legacy regression aid.
""")

Foresight.RecallQualityEvalScript.run()
