alias Ecto.Migrator

profile = Foresight.Profiles.FullMLAuthority.build()
local_ml_backend = System.get_env("FORESIGHT_LOCAL_ML_BACKEND", "bumblebee")
preload_local_models = System.get_env("FORESIGHT_PRELOAD_LOCAL_MODELS", "1")

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

IO.puts("Starting Foresight full-ML authority...")
IO.puts("  URL: http://#{profile.host}:#{profile.port}")
IO.puts("  DB: #{profile.database_url}")
IO.puts("  service key: #{profile.service_api_key}")
IO.puts("  diagnostics: #{if(profile.diagnostics_enabled?, do: "enabled", else: "disabled")}")
IO.puts("  local ML backend: #{local_ml_backend}")
IO.puts("  preload local models: #{preload_local_models}")
IO.puts("  embedder: #{get_in(profile.resolved_config, [:ml, :model_id])}")
IO.puts("  reranker: #{get_in(profile.resolved_config, [:ml, :reranker_model_id])}")
IO.puts(
  "  python executable: #{get_in(profile.resolved_config, [:ml, :python_executable]) || "n/a"}"
)
IO.puts("  python path: #{get_in(profile.resolved_config, [:ml, :python_path]) || "n/a"}")
IO.puts("  llm provider: #{profile.engine_config.provider}")
IO.puts("  llm base URL: #{profile.engine_config.provider_opts[:base_url]}")
IO.puts("  llm model: #{profile.engine_config.provider_opts[:model]}")

migrations_path = Path.expand("../priv/repo/migrations", __DIR__)

{:ok, _migrated, _apps} =
  Migrator.with_repo(Foresight.Repo, fn repo ->
    Migrator.run(repo, migrations_path, :up, all: true)
  end)

IO.puts("  public schema migrated")

{:ok, _pid} =
  Foresight.Supervisor.start_link(Keyword.put(profile.opts, :name, profile.supervisor_name))

Process.sleep(:infinity)
