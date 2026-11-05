defmodule Foresight.Profiles.FullMLAuthority do
  @moduledoc false

  def build(env \\ System.get_env()) do
    host = Map.get(env, "FORESIGHT_HOST", "127.0.0.1")
    port = env_integer(env, "FORESIGHT_PORT", 4012)

    database_url =
      Map.get(
        env,
        "FORESIGHT_DATABASE_URL",
        "postgresql://postgres:postgres@localhost:5432/foresight_full_ml_authority_dev"
      )

    service_api_key = Map.get(env, "FORESIGHT_SERVICE_API_KEY", "foresight-service-key")
    diagnostics_enabled? = Map.get(env, "FORESIGHT_ENABLE_DIAGNOSTICS", "1") == "1"

    llm_base_url =
      Map.get(
        env,
        "FORESIGHT_LLM_BASE_URL",
        Map.get(env, "LMSTUDIO_BASE_URL", "http://127.0.0.1:1234/v1")
      )

    llm_api_key =
      Map.get(env, "FORESIGHT_LLM_API_KEY", Map.get(env, "LMSTUDIO_API_KEY", "lm-studio"))

    llm_provider =
      Map.get(env, "FORESIGHT_LLM_PROVIDER", default_llm_provider(llm_base_url))

    llm_model = Map.get(env, "FORESIGHT_LLM_MODEL", Map.get(env, "LMSTUDIO_MODEL", "local-model"))
    llm_timeout_ms = env_integer(env, "FORESIGHT_LLM_TIMEOUT_MS", 180_000)

    # Atomic-fact pipeline. All default to OFF so an unconfigured
    # authority behaves exactly as before. FORESIGHT_RETAIN_EXTRACTION_MODE enables
    # retain-time atomic-fact extraction ("verbatim" is the validated production
    # mode); FORESIGHT_JSON_LLM_MODEL points the JSON-heavy roles (extraction +
    # consolidation) at a schema-reliable model (e.g. qwen3-coder:30b) distinct from
    # the reader/reflect LLM, defaulting its endpoint/key to the reader's.
    retain_extraction_mode = presence(Map.get(env, "FORESIGHT_RETAIN_EXTRACTION_MODE"))

    # Bound a retain's extraction wall time (nil: unbounded, each chunk only bounded
    # by the LLM timeout) and fan chunks of one item out across this many calls.
    retain_extraction_deadline_ms =
      optional_env_integer(env, "FORESIGHT_RETAIN_EXTRACTION_DEADLINE_MS")

    retain_extraction_concurrency = env_integer(env, "FORESIGHT_RETAIN_EXTRACTION_CONCURRENCY", 1)

    json_llm_provider_opts =
      case presence(Map.get(env, "FORESIGHT_JSON_LLM_MODEL")) do
        nil ->
          nil

        json_model ->
          [
            base_url: Map.get(env, "FORESIGHT_JSON_LLM_BASE_URL", llm_base_url),
            api_key: Map.get(env, "FORESIGHT_JSON_LLM_API_KEY", llm_api_key),
            model: json_model,
            timeout: llm_timeout_ms
          ]
      end

    embedder_model_id = Map.get(env, "FORESIGHT_EMBEDDER_MODEL_ID", "BAAI/bge-small-en-v1.5")

    reranker_model_id =
      Map.get(env, "FORESIGHT_RERANKER_MODEL_ID", "cross-encoder/ms-marco-MiniLM-L-6-v2")

    local_ml_backend = Map.get(env, "FORESIGHT_LOCAL_ML_BACKEND", "bumblebee")
    python_executable = Map.get(env, "FORESIGHT_ML_PYTHON")
    python_path = Map.get(env, "FORESIGHT_ML_PYTHON_PATH")
    preload_models? = Map.get(env, "FORESIGHT_PRELOAD_LOCAL_MODELS", "1") == "1"
    force_cpu? = Map.get(env, "FORESIGHT_LOCAL_ML_FORCE_CPU", "0") == "1"
    trust_remote_code? = Map.get(env, "FORESIGHT_LOCAL_ML_TRUST_REMOTE_CODE", "0") == "1"
    embedding_batch_size = optional_env_integer(env, "FORESIGHT_EMBEDDING_BATCH_SIZE")
    embedding_sequence_length = optional_env_integer(env, "FORESIGHT_EMBEDDING_SEQUENCE_LENGTH")
    reranker_batch_size = optional_env_integer(env, "FORESIGHT_RERANKER_BATCH_SIZE")
    reranker_sequence_length = optional_env_integer(env, "FORESIGHT_RERANKER_SEQUENCE_LENGTH")

    # File ingestion (docling) is ON by default for the authority deployment; set
    # FORESIGHT_FILE_INGESTION=0 to disable. When enabled, the config preflight
    # requires a Python interpreter with docling (FORESIGHT_DOCLING_PYTHON), failing
    # fast with guidance otherwise.
    file_ingestion_enabled? = Map.get(env, "FORESIGHT_FILE_INGESTION", "1") == "1"
    docling_python = Map.get(env, "FORESIGHT_DOCLING_PYTHON")
    docling_python_path = Map.get(env, "FORESIGHT_DOCLING_PYTHON_PATH")

    opts = [
      auth: [
        request_api_key: service_api_key
      ],
      http: [
        enabled: true,
        ip: parse_ip!(host),
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
      ml:
        ml_opts(
          local_ml_backend,
          embedder_model_id,
          reranker_model_id,
          python_executable,
          python_path,
          preload_models?,
          force_cpu?,
          trust_remote_code?,
          embedding_batch_size,
          embedding_sequence_length,
          reranker_batch_size,
          reranker_sequence_length
        ),
      mcp: [
        enabled: false
      ],
      file_ingestion:
        Enum.reject(
          [
            enabled: file_ingestion_enabled?,
            python_executable: docling_python,
            python_path: docling_python_path
          ],
          fn {_key, value} -> is_nil(value) end
        )
    ]

    resolved_config = Foresight.Config.resolve(opts)

    engine_config =
      resolved_config.engine
      |> Map.put(:embedder, embedder_module(local_ml_backend))
      |> Map.put(:reranker, reranker_module(local_ml_backend))
      |> Map.put(:llm, Foresight.LLMs.LlmCore)
      |> Map.put(:provider, llm_provider)
      |> Map.put(:provider_opts,
        base_url: llm_base_url,
        api_key: llm_api_key,
        model: llm_model,
        timeout: llm_timeout_ms
      )
      |> Map.put(:retain_extraction_mode, retain_extraction_mode)
      |> Map.put(:retain_extraction_deadline_ms, retain_extraction_deadline_ms)
      |> Map.put(:retain_extraction_concurrency, retain_extraction_concurrency)
      |> Map.put(:retain_extraction_provider_opts, json_llm_provider_opts)
      |> Map.put(:consolidation_provider_opts, json_llm_provider_opts)

    maybe_configure_remote_embedder(local_ml_backend, embedder_model_id, env)

    %{
      host: host,
      port: port,
      database_url: database_url,
      service_api_key: service_api_key,
      diagnostics_enabled?: diagnostics_enabled?,
      opts: opts,
      resolved_config: resolved_config,
      engine_config: engine_config,
      repo_start_opts: get_in(opts, [:repo, :start_opts]) || [],
      public_repo_start_opts: get_in(opts, [:repo, :public, :start_opts]) || [],
      supervisor_name: Foresight.FullMLAuthoritySupervisor
    }
  end

  defp parse_ip!(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> raise "invalid FORESIGHT_HOST: #{host}"
    end
  end

  defp env_integer(env, key, default) do
    env
    |> Map.get(key, Integer.to_string(default))
    |> String.to_integer()
  end

  defp optional_env_integer(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" -> String.to_integer(value)
      _other -> nil
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp default_llm_provider(base_url) when is_binary(base_url) do
    if String.contains?(base_url, ":11434"), do: "ollama", else: "openai"
  end

  defp default_llm_provider(_base_url), do: "openai"

  defp ml_opts(
         "sentence_transformers",
         embedder_model_id,
         reranker_model_id,
         python_executable,
         python_path,
         preload_models?,
         force_cpu?,
         trust_remote_code?,
         embedding_batch_size,
         embedding_sequence_length,
         reranker_batch_size,
         reranker_sequence_length
       ) do
    [
      enabled: false,
      model_id: embedder_model_id,
      reranker_model_id: reranker_model_id,
      python_worker_module: Foresight.ML.PythonLocalWorker,
      python_worker_name: Foresight.ML.PythonLocalWorker,
      python_executable: python_executable,
      python_path: python_path,
      preload_models: preload_models?,
      force_cpu: force_cpu?,
      trust_remote_code: trust_remote_code?,
      batch_size: embedding_batch_size,
      sequence_length: embedding_sequence_length,
      reranker_batch_size: reranker_batch_size,
      reranker_sequence_length: reranker_sequence_length
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp ml_opts(
         _backend,
         embedder_model_id,
         reranker_model_id,
         _python_executable,
         _python_path,
         _preload_models?,
         _force_cpu?,
         _trust_remote_code?,
         embedding_batch_size,
         embedding_sequence_length,
         reranker_batch_size,
         reranker_sequence_length
       ) do
    [
      enabled: true,
      model_id: embedder_model_id,
      reranker_model_id: reranker_model_id,
      batch_size: embedding_batch_size,
      sequence_length: embedding_sequence_length,
      reranker_batch_size: reranker_batch_size,
      reranker_sequence_length: reranker_sequence_length
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp embedder_module("remote"), do: Foresight.Embedders.Remote
  defp embedder_module("sentence_transformers"), do: Foresight.Embedders.SentenceTransformers
  defp embedder_module(_backend), do: Foresight.Embedders.Bumblebee

  # For the "remote" backend, pin the OpenAI-compatible embedder's connection into
  # application env (symmetric with how the LLM provider_opts are set). The
  # endpoint defaults to the LLM's, so a single FORESIGHT_LLM_BASE_URL drives both
  # reader and embedder in an LM Studio dev loop.
  defp maybe_configure_remote_embedder("remote", embedder_model_id, env) do
    Application.put_env(:foresight, Foresight.Embedders.Remote,
      base_url:
        Map.get(
          env,
          "FORESIGHT_EMBED_BASE_URL",
          Map.get(env, "FORESIGHT_LLM_BASE_URL", Map.get(env, "LMSTUDIO_BASE_URL"))
        ),
      api_key:
        Map.get(
          env,
          "FORESIGHT_EMBED_API_KEY",
          Map.get(env, "FORESIGHT_LLM_API_KEY", Map.get(env, "LMSTUDIO_API_KEY"))
        ),
      model: Map.get(env, "FORESIGHT_EMBED_MODEL", embedder_model_id),
      dimension: env_integer(env, "FORESIGHT_EMBED_DIM", 384),
      timeout_ms: env_integer(env, "FORESIGHT_EMBED_TIMEOUT_MS", 30_000)
    )

    :ok
  end

  defp maybe_configure_remote_embedder(_backend, _embedder_model_id, _env), do: :ok

  defp reranker_module("sentence_transformers"), do: Foresight.Rerankers.SentenceTransformers
  defp reranker_module(_backend), do: Foresight.Rerankers.Bumblebee
end
