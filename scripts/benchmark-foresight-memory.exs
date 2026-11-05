defmodule Foresight.BenchmarkMemoryScript do
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Profiles.FullMLAuthority

  def run do
    profile = FullMLAuthority.build()

    ensure_database(profile.database_url)
    configure_application(profile)
    migrate!(profile)
    start_supervisor!(profile)

    iterations = env_integer("FORESIGHT_BENCH_ITERATIONS", 2)
    item_count = env_integer("FORESIGHT_BENCH_ITEM_COUNT", 1)
    corpus_size = env_integer("FORESIGHT_BENCH_CORPUS_SIZE", item_count)
    recall_budget = System.get_env("FORESIGHT_BENCH_RECALL_BUDGET", "mid")
    recall_max_tokens = env_integer("FORESIGHT_BENCH_RECALL_MAX_TOKENS", 2048)
    recall_rerank_window = env_integer("FORESIGHT_BENCH_RECALL_RERANK_WINDOW", 0)
    bank_id = "bench-" <> Integer.to_string(System.system_time(:millisecond))

    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    {:ok, _bank} =
      Foresight.put_bank(ctx, bank_id, %{
        "name" => "Benchmark Bank",
        "mission" => "Measure retain and recall timing with trace enabled."
      })

    :ok = maybe_apply_rerank_window_override(ctx, recall_rerank_window)

    content =
      System.get_env(
        "FORESIGHT_BENCH_CONTENT",
        "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven."
      )

    query =
      System.get_env(
        "FORESIGHT_BENCH_QUERY",
        "What did Alice and I decide about the Foresight cutover after Oxford?"
      )

    IO.puts("Benchmarking Foresight retain/recall...")
    IO.puts("  backend: #{System.get_env("FORESIGHT_LOCAL_ML_BACKEND", "bumblebee")}")
    IO.puts("  bank: #{bank_id}")
    IO.puts("  iterations: #{iterations}")
    IO.puts("  item_count: #{item_count}")
    IO.puts("  corpus_size: #{corpus_size}")
    IO.puts("  recall_budget: #{recall_budget}")
    IO.puts("  recall_max_tokens: #{recall_max_tokens}")

    IO.puts(
      "  recall_rerank_window: #{if recall_rerank_window > 0, do: recall_rerank_window, else: "adaptive"}"
    )

    IO.puts("")

    1..iterations
    |> Enum.each(fn iteration ->
      retain_items =
        1..corpus_size
        |> Enum.map(fn item_index ->
          target? = item_index <= item_count

          %{
            "content" =>
              if(
                target?,
                do: "#{content} [target item #{item_index}]",
                else:
                  "Distractor memory #{item_index} about unrelated errands, groceries, and beach logistics."
              ),
            "context" => "benchmark",
            "type" => "world",
            "tags" =>
              ["benchmark", "iteration:#{iteration}", "item:#{item_index}"] ++
                if(target?, do: ["target"], else: ["distractor"])
          }
        end)

      retain_payload = %{
        "async" => false,
        "trace" => true,
        "items" => retain_items
      }

      {retain_result, retain_ms} = timed(fn -> Foresight.retain(ctx, retain_payload) end)
      {:ok, retain_body} = retain_result

      {recall_result, recall_ms} =
        timed(fn ->
          Foresight.recall(ctx, %{
            "query" => query,
            "trace" => true,
            "budget" => recall_budget,
            "max_tokens" => recall_max_tokens
          })
        end)

      {:ok, recall_body} = recall_result

      print_iteration(iteration, retain_ms, retain_body, recall_ms, recall_body)
    end)
  end

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

  defp maybe_apply_rerank_window_override(ctx, rerank_window) when rerank_window > 0 do
    {:ok, _response} =
      Foresight.update_bank_config(ctx, ctx.bank, %{
        "HINDSIGHT_API_RECALL_RERANK_WINDOW" => rerank_window
      })

    :ok
  end

  defp maybe_apply_rerank_window_override(_ctx, _rerank_window), do: :ok

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

  defp print_iteration(iteration, retain_ms, retain_body, recall_ms, recall_body) do
    retain_trace = get_in(retain_body, ["trace", "timings_ms"]) || %{}
    recall_trace = get_in(recall_body, ["trace", "timings_ms"]) || %{}

    IO.puts("Iteration #{iteration}")
    IO.puts("  retain wall_ms=#{retain_ms}")
    IO.puts("  retain trace=#{Jason.encode_to_iodata!(retain_trace)}")
    IO.puts("  recall wall_ms=#{recall_ms}")
    IO.puts("  recall trace=#{Jason.encode_to_iodata!(recall_trace)}")
    IO.puts("")
  end

  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    finished_at = System.monotonic_time(:millisecond)
    {result, finished_at - started_at}
  end

  defp env_integer(name, default) do
    name
    |> System.get_env(Integer.to_string(default))
    |> String.to_integer()
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

Foresight.BenchmarkMemoryScript.run()
