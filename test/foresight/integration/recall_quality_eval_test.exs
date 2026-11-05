defmodule Foresight.Integration.RecallQualityEvalTest do
  @moduledoc """
  LEGACY / REGRESSION ONLY. This lane grades with `Foresight.Evals.RecallQuality`, the
  QUARANTINED phrase-matching metric that measures corpus-phrase echo, not retrieval
  quality. Its pass/fail and any top-k numbers MUST NOT be cited as a quality baseline —
  they are the same target the old ranking code was gamed against. It survives only to
  exercise the full ml reflect pipeline end-to-end and to freeze the matcher's behaviour.
  Authoritative recall quality is the LongMemEval harness (`Foresight.Evals.Runner` over
  `Foresight.Evals.RankingMetrics`).
  """
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Evals.RecallQuality
  alias Foresight.Profiles.FullMLAuthority
  alias Foresight.TestSupport.PostgresHarness
  require Logger

  @moduletag :ml
  @moduletag :nightly
  @tag timeout: 1_200_000

  @windows [:adaptive, 20, 40, 80]

  setup do
    cond do
      System.get_env("FORESIGHT_RUN_RECALL_QUALITY_E2E") != "1" ->
        {:ok,
         skip: "Set FORESIGHT_RUN_RECALL_QUALITY_E2E=1 to run the expanded recall quality lane."}

      sentence_transformers_python() == nil ->
        {:ok,
         skip:
           "Set FORESIGHT_ML_PYTHON (or install the default hindsight venv) to run the recall quality lane."}

      true ->
        :ok
    end
  end

  setup_all do
    if System.get_env("FORESIGHT_RUN_RECALL_QUALITY_E2E") == "1" and
         sentence_transformers_python() != nil do
      harness = PostgresHarness.start!()
      repo_config = Application.get_env(:foresight, Foresight.Repo, [])
      public_repo_config = Application.get_env(:foresight, Foresight.PublicRepo, [])
      original_env = Application.get_all_env(:foresight)
      logger_level = Logger.level()
      hf_progress_env = System.get_env("HF_HUB_DISABLE_PROGRESS_BARS")
      transformers_advisory_env = System.get_env("TRANSFORMERS_NO_ADVISORY_WARNINGS")

      env = %{
        "FORESIGHT_DATABASE_URL" => harness.url,
        "FORESIGHT_LOCAL_ML_BACKEND" => "sentence_transformers",
        "FORESIGHT_ML_PYTHON" => sentence_transformers_python(),
        "FORESIGHT_PRELOAD_LOCAL_MODELS" => "1"
      }

      profile = FullMLAuthority.build(env)

      app_env =
        profile.opts
        |> Keyword.put(:http, enabled: false)
        |> Foresight.Config.resolve()

      Application.put_env(:foresight, :backend, Foresight.Backend.Store)
      Application.put_env(:foresight, :auth, app_env.auth)
      Application.put_env(:foresight, :engine, profile.engine_config)
      Application.put_env(:foresight, :file_ingestion, app_env.file_ingestion)
      Application.put_env(:foresight, :health, app_env.health)
      Application.put_env(:foresight, :http, app_env.http)
      Application.put_env(:foresight, :mcp, app_env.mcp)
      Application.put_env(:foresight, :ml, app_env.ml)
      Application.put_env(:foresight, :oban, app_env.oban)
      Application.put_env(:foresight, :repo, app_env.repo)
      Application.put_env(:foresight, :tenancy, app_env.tenancy)
      Application.put_env(:foresight, :tokenizer, app_env.tokenizer)
      Application.put_env(:foresight, :webhook_delivery, app_env.webhook_delivery)

      Application.put_env(
        :foresight,
        Foresight.Repo,
        repo_config
        |> Keyword.merge(profile.repo_start_opts)
        |> Keyword.put(:log, false)
      )

      Application.put_env(
        :foresight,
        Foresight.PublicRepo,
        public_repo_config
        |> Keyword.merge(profile.public_repo_start_opts)
        |> Keyword.put(:log, false)
      )

      System.put_env("HF_HUB_DISABLE_PROGRESS_BARS", "1")
      System.put_env("TRANSFORMERS_NO_ADVISORY_WARNINGS", "1")
      Logger.configure(level: :error)

      start_supervised!(Foresight.Repo)
      start_supervised!(Foresight.PublicRepo)

      migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

      {:ok, _migrated, _apps} =
        Migrator.with_repo(Foresight.Repo, fn repo ->
          Migrator.run(repo, migrations_path, :up, all: true)
        end)

      start_supervised!(
        {Foresight.Supervisor,
         profile.opts
         |> Keyword.put(:http, enabled: false)
         |> Keyword.put(:repo, enabled: false, public: [enabled: false])
         |> Keyword.put(:name, Module.concat(__MODULE__, Supervisor))}
      )

      on_exit(fn ->
        Logger.configure(level: logger_level)
        restore_env_var("HF_HUB_DISABLE_PROGRESS_BARS", hf_progress_env)
        restore_env_var("TRANSFORMERS_NO_ADVISORY_WARNINGS", transformers_advisory_env)

        Enum.each(original_env, fn {key, value} -> Application.put_env(:foresight, key, value) end)

        Application.put_env(:foresight, Foresight.Repo, repo_config)
        Application.put_env(:foresight, Foresight.PublicRepo, public_repo_config)
        PostgresHarness.stop!(harness)
      end)

      {:ok, harness: harness}
    else
      :ok
    end
  end

  test "expanded recall scenarios stay top-1 across rerank windows" do
    bank_id = "quality-test-" <> Integer.to_string(System.system_time(:millisecond))
    ctx = %Context{tenant_id: "default", mode: :mode_a, bank: bank_id}

    assert {:ok, _bank} =
             Foresight.put_bank(ctx, bank_id, %{
               "name" => "Recall Quality Test Bank",
               "mission" => "Surface the correct memory under semantically-near distractors."
             })

    assert {:ok, %{"items_count" => item_count}} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => RecallQuality.corpus()
             })

    assert item_count == length(RecallQuality.corpus())

    for window <- @windows do
      apply_window(ctx, window)

      for scenario <- RecallQuality.scenarios() do
        payload =
          %{
            "query" => scenario.query,
            "trace" => true,
            "budget" => "mid",
            "max_tokens" => 512
          }
          |> maybe_put_query_timestamp(scenario.query_timestamp)

        assert {:ok, %{"results" => results}} = Foresight.recall(ctx, payload)

        top_texts = Enum.map(results, & &1["text"])
        acceptable_texts = RecallQuality.acceptable_texts(scenario)
        hit_index = Enum.find_index(top_texts, &RecallQuality.matches_text?(scenario, &1))

        assert hit_index == 0,
               "window=#{inspect(window)} scenario=#{scenario.id} expected top1 in #{inspect(acceptable_texts)} got #{inspect(Enum.take(top_texts, 3))}"
      end
    end
  end

  defp maybe_put_query_timestamp(payload, nil), do: payload

  defp maybe_put_query_timestamp(payload, timestamp),
    do: Map.put(payload, "query_timestamp", timestamp)

  defp apply_window(ctx, :adaptive) do
    assert {:ok, _response} = Foresight.reset_bank_config(ctx, ctx.bank)
  end

  defp apply_window(ctx, window) do
    assert {:ok, _response} =
             Foresight.update_bank_config(ctx, ctx.bank, %{
               "HINDSIGHT_API_RECALL_RERANK_WINDOW" => window
             })
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

  defp restore_env_var(key, nil), do: System.delete_env(key)
  defp restore_env_var(key, value), do: System.put_env(key, value)
end
