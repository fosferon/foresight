defmodule Foresight.Config do
  @moduledoc false

  @type feature_config :: %{enabled: boolean()}
  @type t :: %{
          auth: map(),
          engine: map(),
          file_ingestion: map(),
          health: map(),
          http: feature_config(),
          mcp: map(),
          ml: map(),
          oban: feature_config(),
          repo: map(),
          tenancy: map(),
          tokenizer: map(),
          webhook_delivery: map()
        }

  @spec resolve(keyword()) :: t()
  def resolve(overrides \\ []) do
    base =
      :foresight
      |> Application.get_all_env()
      # A section explicitly set to nil in the app env (e.g. a test restoring a section
      # whose original value was unset via `put_env(:foresight, :tenancy, nil)`) carries no
      # configuration — it must fall back to the default map, not blow it away. Dropping
      # nil-valued sections here keeps resolve/1 robust to that, in tests and production.
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{}, fn {key, value} -> {key, normalize_feature(value)} end)

    override_map =
      overrides
      |> Enum.into(%{}, fn {key, value} -> {key, normalize_feature(value)} end)

    defaults()
    |> deep_merge(base)
    |> deep_merge(override_map)
  end

  @spec preflight!(t()) :: :ok
  def preflight!(config) do
    config = deep_merge(defaults(), config)

    config
    |> required_optional_apps()
    |> Enum.each(&ensure_optional_app!/1)

    ensure_mcp_runtime!(config)
    ensure_file_ingestion_runtime!(config.file_ingestion)
    ensure_auth!(config)

    :ok
  end

  defp ensure_auth!(%{http: %{enabled: true}, auth: auth}) when is_map(auth) do
    configured_key = auth[:request_api_key] || auth[:api_key]
    allow_anonymous? = auth[:allow_anonymous] == true

    if (is_nil(configured_key) or configured_key == "") and not allow_anonymous? do
      raise ArgumentError,
            "HTTP is enabled but no service credential is configured. Set " <>
              "config :foresight, auth: [request_api_key: ...] (or api_key:), or explicitly " <>
              "opt into an unauthenticated deployment with auth: [allow_anonymous: true]."
    end

    :ok
  end

  defp ensure_auth!(_config), do: :ok

  @spec get(atom(), atom(), any()) :: any()
  def get(section, key, default \\ nil) when is_atom(section) and is_atom(key) do
    section(section)
    |> Map.get(key, default)
  end

  @spec section(atom()) :: map()
  def section(name) when is_atom(name) do
    case Application.get_env(:foresight, name, %{}) do
      value when is_map(value) ->
        value

      value when is_list(value) ->
        if Keyword.keyword?(value), do: Enum.into(value, %{}), else: %{}

      _other ->
        %{}
    end
  end

  defp defaults do
    %{
      auth: %{
        api_key: nil,
        request_api_key: nil,
        allow_bearer_passthrough: false,
        tenant_scopes: %{}
      },
      engine: %{
        storage: Foresight.Storage.Ecto,
        repo: Foresight.Repo,
        embedder: Foresight.Embedders.Noop,
        # Passthrough, not Bumblebee (audit, Finding 1). These two defaults sat
        # inconsistent: the embedder default deliberately needs no dependency, while the
        # reranker default pulled in nx + bumblebee + exla + ortex + tokenizers. Since a
        # dependency's own config/config.exs is NOT loaded by the parent app, THIS map is
        # what a consumer actually gets — so the shipped default made preflight demand
        # :nx and a bare consumer could not boot at all.
        #
        # Passthrough is a true no-op: it preserves fusion order and reseeds rerank_score,
        # so recall works and simply is not reranked. Bumblebee remains one line of config
        # away, and anyone choosing it has to add those deps regardless.
        reranker: Foresight.Rerankers.Passthrough,
        llm: Foresight.LLMs.LlmCore,
        queue: Foresight.AsyncQueues.Oban,
        oban_name: Foresight.Oban,
        reranker_serving_name: Foresight.ML.RerankerServing,
        provider: llm_core_native(),
        provider_opts: [],
        reflect_max_iterations: 10,
        reflect_min_grounding_count: 1,
        reflect_min_diverse_grounding_count: 1,
        reflect_min_provenance_cluster_count: 1,
        reflect_min_source_provenance_cluster_count: 0,
        reflect_min_source_family_count: 0,
        reflect_min_source_lineage_count: 0,
        reflect_min_evidence_family_count: 0,
        reflect_max_context_tokens: 100_000,
        reflect_timeout_ms: 120_000
      },
      file_ingestion: %{
        enabled: false,
        converter: Foresight.DocumentConverters.Docling,
        converter_opts: [],
        worker: Foresight.Ingestion.DoclingWorker,
        python_executable: nil,
        python_path: nil
      },
      http: %{enabled: false, tenant_resolver: nil, tenant_resolver_opts: []},
      health: %{checker: Foresight.Health},
      mcp: %{
        enabled: false,
        registry: Hermes.Server.Registry,
        server: Foresight.MCP.Server,
        # When true, a POST that carries no session header and is not an
        # initialize gets a fabricated, pre-initialized session so clients ported from
        # Python Hindsight (bare tools/call, no handshake) work unchanged. Off by default:
        # it makes the negotiated protocolVersion and capabilities the server's invention
        # rather than the client's declaration, which is a fair trade only when an operator
        # has chosen it.
        lenient_session: false
      },
      ml: %{
        enabled: false,
        module: Foresight.ML.Serving,
        model_id: "BAAI/bge-small-en-v1.5",
        reranker_module: Foresight.ML.RerankerServing,
        reranker_model_id: "cross-encoder/ms-marco-MiniLM-L-6-v2",
        reranker_serving_name: Foresight.ML.RerankerServing,
        python_worker_module: Foresight.ML.PythonLocalWorker,
        python_worker_name: Foresight.ML.PythonLocalWorker,
        python_executable: nil,
        python_path: nil,
        preload_models: false,
        force_cpu: false,
        trust_remote_code: false,
        batch_size: nil,
        sequence_length: nil,
        reranker_batch_size: nil,
        reranker_sequence_length: nil,
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm,
        serving_name: Foresight.ML.Serving
      },
      tokenizer: %{
        identifier: "Xenova/text-embedding-ada-002",
        path: nil,
        use_cache: true
      },
      oban: %{
        enabled: false,
        module: Foresight.Oban,
        name: Foresight.Oban,
        peer: false,
        plugins: false,
        queues: [
          foresight_retain: 10,
          foresight_consolidate: 5,
          foresight_webhook_delivery: 5,
          foresight_embedding_backfill: 5,
          foresight_refresh_mental_model: 5,
          foresight_migrate_bank: 3,
          foresight_probe_bank: 3
        ]
      },
      repo: %{
        enabled: false,
        module: Foresight.Repo,
        public: %{
          enabled: false,
          module: Foresight.PublicRepo
        }
      },
      tenancy: %{
        enabled: false,
        template_prefix: "foresight_template",
        known_prefixes: [],
        rls_enabled: false,
        reset_role_on_connect: true,
        posture_monitor: %{
          enabled: false,
          module: Foresight.Tenancy.PostureMonitor,
          name: Foresight.Tenancy.PostureMonitor,
          interval_ms: :timer.minutes(1)
        },
        runtime_registry: Foresight.Tenancy.RuntimeRegistry,
        runtime_supervisor: Foresight.Tenancy.RuntimeSupervisor,
        reconciler: Foresight.Tenancy.Reconciler
      },
      webhook_delivery: %{http_client: Foresight.Webhooks.HttpcClient}
    }
  end

  defp normalize_feature(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, nested_value} -> {key, normalize_feature(nested_value)} end)
  end

  defp normalize_feature([]), do: []

  defp normalize_feature(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{}, fn {key, nested_value} -> {key, normalize_feature(nested_value)} end)
    else
      Enum.map(value, &normalize_feature/1)
    end
  end

  defp normalize_feature(value), do: value

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = left_value, %{} = right_value -> deep_merge(left_value, right_value)
      _key, _left_value, right_value -> right_value
    end)
  end

  defp required_optional_apps(%{
         http: %{enabled: true},
         repo: %{enabled: true},
         oban: %{enabled: true},
         ml: %{enabled: true}
       }) do
    [
      :bandit,
      :plug,
      :ecto_sql,
      :postgrex,
      :pgvector,
      :oban,
      :erlport,
      :nx,
      :bumblebee,
      :exla,
      :ortex,
      :tokenizers
    ]
  end

  defp required_optional_apps(config) do
    local_ml_modules = local_ml_modules(config)

    []
    |> maybe_concat(config.http.enabled, [:bandit, :plug])
    |> maybe_concat(config.mcp.enabled, [:hermes_mcp])
    |> maybe_concat(config.repo.enabled, [:ecto_sql, :postgrex, :pgvector])
    |> maybe_concat(get_in(config, [:repo, :public, :enabled]) == true, [
      :ecto_sql,
      :postgrex,
      :pgvector
    ])
    |> maybe_concat(config.oban.enabled, [:oban])
    |> maybe_concat(config.file_ingestion.enabled, [:erlport])
    |> maybe_concat(local_bumblebee_modules(local_ml_modules) != [], [
      :nx,
      :bumblebee,
      :exla,
      :ortex,
      :tokenizers
    ])
    |> maybe_concat(local_python_ml_modules(local_ml_modules) != [], [:erlport])
    |> Enum.uniq()
  end

  defp local_ml_modules(config) do
    []
    |> maybe_concat(local_ml_module_kind(get_in(config, [:engine, :embedder])) == :bumblebee, [
      :embedder_bumblebee
    ])
    |> maybe_concat(local_ml_module_kind(get_in(config, [:engine, :embedder])) == :python, [
      :embedder_python
    ])
    |> maybe_concat(local_ml_module_kind(get_in(config, [:engine, :reranker])) == :bumblebee, [
      :reranker_bumblebee
    ])
    |> maybe_concat(local_ml_module_kind(get_in(config, [:engine, :reranker])) == :python, [
      :reranker_python
    ])
  end

  defp local_bumblebee_modules(modules) do
    Enum.filter(modules, &(&1 in [:embedder_bumblebee, :reranker_bumblebee]))
  end

  defp local_python_ml_modules(modules) do
    Enum.filter(modules, &(&1 in [:embedder_python, :reranker_python]))
  end

  defp local_ml_module_kind(module)
       when module in [Foresight.Embedders.Bumblebee, Foresight.Rerankers.Bumblebee],
       do: :bumblebee

  defp local_ml_module_kind(module)
       when module in [
              Foresight.Embedders.SentenceTransformers,
              Foresight.Rerankers.SentenceTransformers
            ],
       do: :python

  defp local_ml_module_kind(_module), do: nil

  defp maybe_concat(list, true, additions), do: list ++ additions
  defp maybe_concat(list, false, _additions), do: list

  defp ensure_optional_app!(app) do
    case Application.spec(app) do
      nil ->
        raise """
        Foresight capability preflight failed: optional dependency #{inspect(app)} is not available.
        Add/fetch the dependency before enabling the related capability.
        """

      _spec ->
        :ok
    end
  end

  defp ensure_mcp_runtime!(%{mcp: %{enabled: true}, http: %{enabled: false}}) do
    raise """
    Foresight capability preflight failed: MCP is enabled but HTTP is disabled.
    Streamable-HTTP MCP requires the HTTP face to be enabled.
    """
  end

  defp ensure_mcp_runtime!(%{mcp: %{enabled: true} = mcp}) do
    registry = Map.get(mcp, :registry)
    server = Map.get(mcp, :server)

    Enum.each([{registry, :registry}, {server, :server}], fn {module, kind} ->
      unless is_atom(module) and Code.ensure_loaded?(module) do
        raise """
        Foresight capability preflight failed: MCP is enabled but the configured #{kind} module #{inspect(module)} is unavailable.
        Ensure hermes_mcp is installed and the MCP modules compile before enabling the MCP face.
        """
      end
    end)
  end

  defp ensure_mcp_runtime!(_config), do: :ok

  defp ensure_file_ingestion_runtime!(%{enabled: true} = config) do
    python_executable =
      config[:python_executable] ||
        System.get_env("FORESIGHT_DOCLING_PYTHON") ||
        "python3"

    executable_path =
      cond do
        Path.type(python_executable) == :absolute and File.exists?(python_executable) ->
          python_executable

        resolved = System.find_executable(python_executable) ->
          resolved

        true ->
          raise """
          Foresight capability preflight failed: file ingestion is enabled but the configured Python executable #{inspect(python_executable)} is not available.
          Set :file_ingestion, :python_executable (or FORESIGHT_DOCLING_PYTHON) to a working interpreter with Docling installed.
          """
      end

    case System.cmd(
           executable_path,
           ["-c", "from docling.document_converter import DocumentConverter"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise """
        Foresight capability preflight failed: file ingestion is enabled but Docling is unavailable in #{inspect(executable_path)} (exit #{status}).
        Ensure the configured interpreter has the `docling` package installed.

        Probe output:
        #{String.trim(output)}
        """
    end
  end

  defp ensure_file_ingestion_runtime!(_config), do: :ok

  defp llm_core_native, do: :"Elixir.LlmCore.LLM.Native"
end
