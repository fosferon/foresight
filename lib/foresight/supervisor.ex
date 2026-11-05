defmodule Foresight.Supervisor do
  @moduledoc """
  The embeddable supervision entry point.

  Starting `Foresight.Supervisor` under your application's supervisor boots the
  runtime — storage, queues, and the optional HTTP and MCP faces — from
  application config. Embedders use this instead of the OTP application's own
  top-level start, so the runtime belongs to the consuming app's tree.
  """

  use Supervisor

  alias Foresight.Config

  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, init_opts, name: name)
  end

  @impl true
  def init(opts) do
    config = Config.resolve(opts)
    :ok = Config.preflight!(config)
    runtime_names = Keyword.get(opts, :runtime_names, %{})

    children =
      []
      |> maybe_add_repo(config, runtime_names)
      |> maybe_add_public_repo(config, runtime_names)
      |> maybe_add_tenancy(config, runtime_names)
      |> maybe_add_posture_monitor(config, runtime_names)
      |> maybe_add_oban(config, runtime_names)
      |> maybe_add_mcp(config, runtime_names)
      |> maybe_add_http(config, runtime_names)
      |> maybe_add_file_ingestion(config, runtime_names)
      |> maybe_add_python_ml_worker(config, runtime_names)
      |> maybe_add_ml(config, runtime_names)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_add_repo(
         children,
         %{repo: %{enabled: true} = repo_config, tenancy: tenancy_config},
         runtime_names
       ) do
    add_repo_child(children, repo_config, tenancy_config, runtime_names, :repo)
  end

  defp maybe_add_repo(children, _config, _runtime_names), do: children

  defp maybe_add_public_repo(
         children,
         %{repo: %{public: %{enabled: true} = repo_config}, tenancy: tenancy_config},
         runtime_names
       ) do
    add_repo_child(children, repo_config, tenancy_config, runtime_names, :public_repo)
  end

  defp maybe_add_public_repo(children, _config, _runtime_names), do: children

  defp add_repo_child(children, repo_config, tenancy_config, runtime_names, runtime_key) do
    repo_module = Map.get(repo_config, :module, Foresight.Repo)
    name = Map.get(runtime_names, runtime_key, Map.get(repo_config, :name, repo_module))

    start_opts =
      repo_config
      |> Map.get(:start_opts, [])
      |> normalize_start_opts()
      |> maybe_with_reset_role(tenancy_config)

    [
      %{
        id: {runtime_key, name},
        start: {repo_module, :start_link, [Keyword.put(start_opts, :name, name)]}
      }
      | children
    ]
  end

  defp maybe_with_reset_role(start_opts, %{enabled: true, reset_role_on_connect: true}) do
    # Reset both the role AND the tenant-prefix GUC on every fresh checkout, so a
    # stale non-LOCAL scope left by a killed process can't ride a pooled connection
    # into the next tenant's request.
    Keyword.put_new(start_opts, :after_connect, {Foresight.Tenancy, :reset_connection, []})
  end

  defp maybe_with_reset_role(start_opts, _tenancy_config), do: start_opts

  defp normalize_start_opts(start_opts) when is_map(start_opts), do: Enum.into(start_opts, [])
  defp normalize_start_opts(start_opts) when is_list(start_opts), do: start_opts

  defp maybe_add_tenancy(
         children,
         %{tenancy: %{enabled: true} = tenancy_config} = config,
         runtime_names
       ) do
    registry_name =
      Map.get(runtime_names, :tenancy_registry, Map.get(tenancy_config, :runtime_registry))

    runtime_supervisor_name =
      Map.get(
        runtime_names,
        :tenancy_runtime_supervisor,
        Map.get(tenancy_config, :runtime_supervisor)
      )

    reconciler_name =
      Map.get(runtime_names, :tenancy_reconciler, Map.get(tenancy_config, :reconciler))

    reconciler_module = Map.get(tenancy_config, :reconciler, Foresight.Tenancy.Reconciler)

    tenant_key_cache_name =
      Map.get(runtime_names, :tenant_key_cache, Foresight.Tenancy.TenantKeyCache)

    children ++
      [
        %{
          id: {:tenant_key_cache, tenant_key_cache_name},
          start: {Foresight.Tenancy.TenantKeyCache, :start_link, [[name: tenant_key_cache_name]]}
        },
        %{
          id: {:tenancy_reconciler, reconciler_name},
          start:
            {reconciler_module, :start_link,
             [
               [
                 name: reconciler_name,
                 config: config,
                 runtime_registry: registry_name,
                 runtime_supervisor: runtime_supervisor_name
               ]
             ]}
        },
        %{
          id: {:tenancy_runtime_supervisor, runtime_supervisor_name},
          start:
            {Foresight.Tenancy.RuntimeSupervisor, :start_link, [[name: runtime_supervisor_name]]}
        },
        %{
          id: {:tenancy_registry, registry_name},
          start: {Registry, :start_link, [[keys: :unique, name: registry_name]]}
        }
      ]
  end

  defp maybe_add_tenancy(children, _config, _runtime_names), do: children

  defp maybe_add_posture_monitor(
         children,
         %{tenancy: %{enabled: true, posture_monitor: %{enabled: true}} = _tenancy_config} =
           config,
         runtime_names
       ) do
    posture_monitor_module =
      get_in(config, [:tenancy, :posture_monitor, :module]) || Foresight.Tenancy.PostureMonitor

    name =
      Map.get(
        runtime_names,
        :tenancy_posture_monitor,
        get_in(config, [:tenancy, :posture_monitor, :name]) || posture_monitor_module
      )

    children ++
      [
        %{
          id: {:tenancy_posture_monitor, name},
          start:
            {posture_monitor_module, :start_link,
             [[name: name, config: config, repo: get_in(config, [:repo, :module])]]}
        }
      ]
  end

  defp maybe_add_posture_monitor(children, _config, _runtime_names), do: children

  defp maybe_add_oban(
         children,
         %{oban: %{enabled: true} = oban_config, repo: repo_config},
         runtime_names
       ) do
    oban_module = Map.get(oban_config, :module, Foresight.Oban)
    name = Map.get(runtime_names, :oban, Map.get(oban_config, :name, oban_module))
    repo_module = Map.get(repo_config, :module, Foresight.Repo)

    child_spec =
      oban_module.child_spec(oban_options(oban_config, repo_module, name))

    [child_spec | children]
  end

  defp maybe_add_oban(children, _config, _runtime_names), do: children

  defp maybe_add_http(children, %{http: %{enabled: true}} = config, runtime_names) do
    name = Map.get(runtime_names, :http, Foresight.HTTP.Endpoint)

    [
      Foresight.HTTP.Endpoint.child_spec(
        name: name,
        config: config,
        ip: get_in(config, [:http, :ip]) || {127, 0, 0, 1},
        port: get_in(config, [:http, :port]) || 4001
      )
      | children
    ]
  end

  defp maybe_add_http(children, _config, _runtime_names), do: children

  defp maybe_add_mcp(children, %{mcp: %{enabled: true} = mcp_config}, runtime_names) do
    registry_module = Map.get(mcp_config, :registry, Hermes.Server.Registry)
    server_module = Map.get(mcp_config, :server, Foresight.MCP.Server)
    server_name = Map.get(runtime_names, :mcp_server, server_module)

    server_opts =
      mcp_config
      |> Map.take([:transport, :request_timeout])
      |> Enum.into([])
      |> Keyword.put_new(:transport, :streamable_http)
      |> Keyword.put_new(:request_timeout, 120_000)
      |> Keyword.put(:name, server_name)

    # Registry BEFORE server: the Hermes server registers itself on start, so listing it
    # first meant mcp: [enabled: true] could never boot.
    [
      registry_module,
      {server_module, server_opts}
      | children
    ]
  end

  defp maybe_add_mcp(children, _config, _runtime_names), do: children

  defp maybe_add_file_ingestion(
         children,
         %{file_ingestion: %{enabled: true} = file_config},
         runtime_names
       ) do
    worker_module = Map.get(file_config, :worker, Foresight.Ingestion.DoclingWorker)
    name = Map.get(runtime_names, :file_ingestion, worker_module)

    start_opts =
      file_config
      |> Map.take([:python_executable, :python_path])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.new()
      |> Keyword.put(:name, name)

    [
      %{
        id: {:file_ingestion, name},
        start: {worker_module, :start_link, [start_opts]}
      }
      | children
    ]
  end

  defp maybe_add_file_ingestion(children, _config, _runtime_names), do: children

  defp maybe_add_python_ml_worker(
         children,
         %{ml: ml_config, engine: engine_config},
         runtime_names
       ) do
    if local_python_ml_runtime?(engine_config) do
      worker_module = Map.get(ml_config, :python_worker_module, Foresight.ML.PythonLocalWorker)

      name =
        Map.get(
          runtime_names,
          :python_ml_worker,
          Map.get(ml_config, :python_worker_name, worker_module)
        )

      start_opts =
        ml_config
        |> Map.take([
          :model_id,
          :reranker_model_id,
          :python_executable,
          :python_path,
          :preload_models,
          :force_cpu,
          :trust_remote_code
        ])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Keyword.new()
        |> Keyword.put(:name, name)

      [
        %{
          id: {:python_ml_worker, name},
          start: {worker_module, :start_link, [start_opts]}
        }
        | children
      ]
    else
      children
    end
  end

  defp local_python_ml_runtime?(engine_config) do
    python_ml_module?(Map.get(engine_config, :embedder)) or
      python_ml_module?(Map.get(engine_config, :reranker))
  end

  defp python_ml_module?(module)
       when module in [
              Foresight.Embedders.SentenceTransformers,
              Foresight.Rerankers.SentenceTransformers
            ],
       do: true

  defp python_ml_module?(_module), do: false

  defp maybe_add_ml(children, %{ml: %{enabled: true} = ml_config}, runtime_names) do
    name = Map.get(runtime_names, :ml, Foresight.ML.Serving)
    ml_module = Map.get(ml_config, :module, Foresight.ML.Serving)

    reranker_name =
      Map.get(
        runtime_names,
        :reranker_ml,
        Map.get(ml_config, :reranker_serving_name, Foresight.ML.RerankerServing)
      )

    reranker_module = Map.get(ml_config, :reranker_module, Foresight.ML.RerankerServing)

    [
      reranker_module.child_spec(
        ml_config
        |> Enum.into([])
        |> Keyword.put(:name, reranker_name)
        |> Keyword.put(:model_id, Map.get(ml_config, :reranker_model_id))
      ),
      ml_module.child_spec(Keyword.put(ml_config |> Enum.into([]), :name, name))
    ] ++ entailment_children(ml_config) ++ children
  end

  defp maybe_add_ml(children, _config, _runtime_names), do: children

  # Start the NLI entailment serving ONLY when its name is configured — the LLM-judge
  # and Noop verifiers need no serving, so the NLI model loads strictly opt-in.
  defp entailment_children(ml_config) do
    case Map.get(ml_config, :entailment_serving_name) do
      nil ->
        []

      serving_name ->
        module = Map.get(ml_config, :entailment_module, Foresight.ML.EntailmentServing)

        [
          module.child_spec(
            ml_config
            |> Enum.into([])
            |> Keyword.put(:name, serving_name)
            |> Keyword.put(:model_id, Map.get(ml_config, :entailment_model_id))
          )
        ]
    end
  end

  defp oban_options(oban_config, repo_module, name) do
    oban_config
    |> Map.take([
      :dispatch_cooldown,
      :engine,
      :get_dynamic_repo,
      :insert_trigger,
      :log,
      :node,
      :notifier,
      :peer,
      :plugins,
      :prefix,
      :queues,
      :shutdown_grace_period,
      :stage_interval,
      :testing
    ])
    |> Enum.into([])
    # Config.resolve/1 normalizes keyword lists into maps; Oban requires :queues and
    # :plugins as keyword lists. Convert them back or Oban.Config.new/1 rejects the
    # supervisor child and the whole async subsystem fails to boot.
    |> normalize_oban_keyword(:queues)
    |> normalize_oban_keyword(:plugins)
    |> Keyword.put(:name, name)
    |> Keyword.put(:repo, repo_module)
  end

  defp normalize_oban_keyword(opts, key) do
    case Keyword.get(opts, key) do
      %{} = map -> Keyword.put(opts, key, deep_to_keyword(map))
      _ -> opts
    end
  end

  # Config.resolve/1 maps keyword lists to maps recursively; Oban expects nested
  # options (e.g. queues: [q: [limit: 10, paused: true]]) as keyword lists too.
  defp deep_to_keyword(map) when is_map(map) do
    Enum.map(map, fn {key, value} -> {key, deep_to_keyword(value)} end)
  end

  defp deep_to_keyword(value), do: value
end
