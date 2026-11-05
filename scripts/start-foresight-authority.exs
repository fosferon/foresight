alias Ecto.Migrator

host = System.get_env("FORESIGHT_HOST", "127.0.0.1")
port = String.to_integer(System.get_env("FORESIGHT_PORT", "4011"))

database_url =
  System.get_env(
    "FORESIGHT_DATABASE_URL",
    "postgresql://postgres:postgres@localhost:5432/foresight_live_authority_dev"
  )

service_api_key = System.get_env("FORESIGHT_SERVICE_API_KEY", "foresight-service-key")
diagnostics_enabled? = System.get_env("FORESIGHT_ENABLE_DIAGNOSTICS", "1") == "1"

ip =
  case :inet.parse_address(String.to_charlist(host)) do
    {:ok, parsed} -> parsed
    {:error, _reason} -> raise "invalid FORESIGHT_HOST: #{host}"
  end

opts = [
  auth: [
    request_api_key: service_api_key
  ],
  http: [
    enabled: true,
    ip: ip,
    port: port,
    diagnostics: [enabled: diagnostics_enabled?]
  ],
  repo: [
    enabled: true,
    module: Foresight.Repo,
    start_opts: [
      url: database_url,
      pool_size: 10
    ],
    public: [
      enabled: true,
      module: Foresight.PublicRepo,
      start_opts: [
        url: database_url,
        pool_size: 2
      ]
    ]
  ],
  tenancy: [
    enabled: true,
    rls_enabled: true,
    posture_monitor: [
      enabled: true,
      interval_ms: :timer.seconds(30)
    ]
  ],
  oban: [
    enabled: false
  ],
  ml: [
    enabled: false
  ],
  mcp: [
    enabled: false
  ],
  file_ingestion: [
    enabled: false
  ]
]

repo_start_opts = get_in(opts, [:repo, :start_opts]) || []
public_repo_start_opts = get_in(opts, [:repo, :public, :start_opts]) || []
resolved_config = Foresight.Config.resolve(opts)

engine_config =
  resolved_config.engine
  |> Map.put(:reranker, Foresight.Rerankers.Passthrough)
  |> Map.put(:llm, Foresight.LLMs.Noop)

Application.put_env(:foresight, :backend, Foresight.Backend.Store)
Application.put_env(:foresight, :auth, resolved_config.auth)
Application.put_env(:foresight, :engine, engine_config)
Application.put_env(:foresight, :file_ingestion, resolved_config.file_ingestion)
Application.put_env(:foresight, :health, resolved_config.health)
Application.put_env(:foresight, :http, resolved_config.http)
Application.put_env(:foresight, :mcp, resolved_config.mcp)
Application.put_env(:foresight, :ml, resolved_config.ml)
Application.put_env(:foresight, :oban, resolved_config.oban)
Application.put_env(:foresight, :repo, resolved_config.repo)
Application.put_env(:foresight, :tenancy, resolved_config.tenancy)
Application.put_env(:foresight, :tokenizer, resolved_config.tokenizer)
Application.put_env(:foresight, :webhook_delivery, resolved_config.webhook_delivery)

Application.put_env(
  :foresight,
  Foresight.Repo,
  Keyword.merge(Foresight.Repo.config(), repo_start_opts)
)

Application.put_env(
  :foresight,
  Foresight.PublicRepo,
  Keyword.merge(Foresight.PublicRepo.config(), public_repo_start_opts)
)

IO.puts("Starting Foresight live authority...")
IO.puts("  URL: http://#{host}:#{port}")
IO.puts("  DB: #{database_url}")
IO.puts("  service key: #{service_api_key}")
IO.puts("  diagnostics: #{if(diagnostics_enabled?, do: "enabled", else: "disabled")}")

migrations_path = Path.expand("../priv/repo/migrations", __DIR__)

{:ok, _migrated, _apps} =
  Migrator.with_repo(Foresight.Repo, fn repo ->
    Migrator.run(repo, migrations_path, :up, all: true)
  end)

IO.puts("  public schema migrated")

{:ok, _pid} =
  Foresight.Supervisor.start_link(Keyword.put(opts, :name, Foresight.LiveAuthoritySupervisor))

Process.sleep(:infinity)
