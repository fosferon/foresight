defmodule Foresight.CompareRecallQualityWithHindsightScript do
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.RecallQuality
  alias Foresight.Profiles.FullMLAuthority
  require Logger

  @default_bank_id "quality-compare"

  def run do
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    Logger.configure(level: :info)

    foresight_profile = FullMLAuthority.build()
    hindsight_client = hindsight_client()
    bank_id = compare_bank_id()

    ensure_database(foresight_profile.database_url)
    configure_foresight(foresight_profile)
    migrate!(foresight_profile)
    start_supervisor!(foresight_profile)

    foresight_ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}
    corpus = RecallQuality.corpus()
    scenarios = RecallQuality.scenarios()

    seed_foresight!(foresight_ctx, bank_id, corpus)
    seed_hindsight!(hindsight_client, bank_id, corpus)

    IO.puts("Comparing recall quality against live Hindsight...")
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
          "#{scenario.id} [#{scenario.class}] foresight=#{render_rank(foresight.hit_rank)} hindsight=#{render_rank(hindsight.hit_rank)}"
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
        "budget" => "mid",
        "max_tokens" => 512
      }
      |> maybe_put_query_timestamp(scenario.query_timestamp)

    {{:ok, response}, elapsed_ms} = timed(fn -> Foresight.recall(ctx, payload) end)
    build_outcome(response, elapsed_ms, scenario)
  end

  defp evaluate_hindsight_scenario(client, bank_id, scenario) do
    path = "/v1/default/banks/#{bank_id}/memories/recall"

    payload =
      %{
        "query" => scenario.query,
        "trace" => true,
        "max_tokens" => 512,
        "include" => %{"chunks" => %{}, "source_facts" => %{}}
      }
      |> maybe_put_query_timestamp(scenario.query_timestamp)

    {response, elapsed_ms} =
      timed(fn ->
        request_json!(client, :post, path, payload)
      end)

    build_outcome(response, elapsed_ms, scenario)
  end

  defp build_outcome(response, elapsed_ms, scenario) do
    results = Map.get(response, "results", [])
    top_texts = Enum.map(results, & &1["text"])
    hit_index = Enum.find_index(top_texts, &RecallQuality.matches_text?(scenario, &1))

    %{
      hit_rank: if(is_nil(hit_index), do: nil, else: hit_index + 1),
      hit_top_3?: is_integer(hit_index) and hit_index < 3,
      elapsed_ms: elapsed_ms,
      top_texts: Enum.take(top_texts, 3)
    }
  end

  defp maybe_print_delta(scenario, foresight, hindsight) do
    if foresight.hit_rank != hindsight.hit_rank do
      IO.puts("  query: #{scenario.query}")
      IO.puts("  foresight_top3: #{inspect(foresight.top_texts)}")
      IO.puts("  hindsight_top3: #{inspect(hindsight.top_texts)}")
    end
  end

  defp print_summary(results) do
    foresight_top1 = Enum.count(results, &(&1.foresight.hit_rank == 1))
    hindsight_top1 = Enum.count(results, &(&1.hindsight.hit_rank == 1))
    foresight_top3 = Enum.count(results, & &1.foresight.hit_top_3?)
    hindsight_top3 = Enum.count(results, & &1.hindsight.hit_top_3?)
    ties = Enum.count(results, &(&1.foresight.hit_rank == &1.hindsight.hit_rank))

    IO.puts("")
    IO.puts("Summary")
    IO.puts("  foresight_top1: #{foresight_top1}/#{length(results)}")
    IO.puts("  hindsight_top1: #{hindsight_top1}/#{length(results)}")
    IO.puts("  foresight_top3: #{foresight_top3}/#{length(results)}")
    IO.puts("  hindsight_top3: #{hindsight_top3}/#{length(results)}")
    IO.puts("  matching_hit_rank: #{ties}/#{length(results)}")
    IO.puts("  foresight_avg_ms: #{average_ms(Enum.map(results, & &1.foresight.elapsed_ms))}")
    IO.puts("  hindsight_avg_ms: #{average_ms(Enum.map(results, & &1.hindsight.elapsed_ms))}")
  end

  defp average_ms([]), do: 0
  defp average_ms(values), do: round(Enum.sum(values) / length(values))

  defp render_rank(nil), do: "miss"
  defp render_rank(rank), do: "top#{rank}"

  defp seed_foresight!(ctx, bank_id, corpus) do
    {:ok, _} =
      Foresight.put_bank(ctx, bank_id, %{
        "name" => "Recall Quality Compare",
        "mission" => "Compare recall behavior with live Hindsight."
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
        "name" => "Recall Quality Compare",
        "mission" => "Compare recall behavior with Foresight."
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
    metric (corpus-phrase echo, NOT retrieval quality). Do NOT cite its numbers as a
    quality baseline. Authoritative measure: the LongMemEval harness (Foresight.Evals.Runner).
""")

Foresight.CompareRecallQualityWithHindsightScript.run()
