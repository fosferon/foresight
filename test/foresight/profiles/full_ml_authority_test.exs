defmodule Foresight.Profiles.FullMLAuthorityTest do
  use ExUnit.Case, async: true

  test "build/1 returns a reusable full-ML authority profile with safe local defaults" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_HOST" => "127.0.0.1",
        "FORESIGHT_PORT" => "4123",
        "FORESIGHT_DATABASE_URL" =>
          "postgresql://postgres:postgres@localhost:5432/foresight_ml_test",
        "FORESIGHT_LLM_BASE_URL" => "http://127.0.0.1:1234/v1",
        "FORESIGHT_LLM_API_KEY" => "lm-studio",
        "FORESIGHT_LLM_MODEL" => "qwen-test"
      })

    assert profile.host == "127.0.0.1"
    assert profile.port == 4123
    assert profile.database_url =~ "foresight_ml_test"
    assert profile.service_api_key == "foresight-service-key"
    assert profile.resolved_config.ml.enabled
    assert is_map(profile.resolved_config.ml)
    assert profile.engine_config.embedder == Foresight.Embedders.Bumblebee
    assert profile.engine_config.reranker == Foresight.Rerankers.Bumblebee
    assert profile.engine_config.llm == Foresight.LLMs.LlmCore
    assert profile.engine_config.provider == "openai"
    assert profile.engine_config.provider_opts[:base_url] == "http://127.0.0.1:1234/v1"
    assert profile.engine_config.provider_opts[:api_key] == "lm-studio"
    assert profile.engine_config.provider_opts[:model] == "qwen-test"
    assert get_in(profile.opts, [:repo, :public, :enabled])
    assert get_in(profile.opts, [:http, :enabled])
    assert get_in(profile.opts, [:tenancy, :enabled])
    # FORESIGHT_FILE_INGESTION=0 disables the docling upload path (default is on,
    # but the test environment has no docling interpreter).
    assert get_in(profile.opts, [:file_ingestion, :enabled]) == false
  end

  test "build/1 infers the ollama provider from a local ollama base url" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_LLM_BASE_URL" => "http://gpu-host.local:11434",
        "FORESIGHT_LLM_MODEL" => "qwen3:8b"
      })

    assert profile.engine_config.provider == "ollama"
    assert profile.engine_config.provider_opts[:base_url] == "http://gpu-host.local:11434"
    assert profile.engine_config.provider_opts[:model] == "qwen3:8b"
  end

  test "build/1 can switch the local ML backend to sentence-transformers" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_LOCAL_ML_BACKEND" => "sentence_transformers",
        "FORESIGHT_ML_PYTHON" => "/tmp/hindsight-venv/bin/python3"
      })

    assert profile.engine_config.embedder == Foresight.Embedders.SentenceTransformers
    assert profile.engine_config.reranker == Foresight.Rerankers.SentenceTransformers
    assert get_in(profile.opts, [:ml, :enabled]) == false
    assert get_in(profile.opts, [:ml, :preload_models]) == true
    assert get_in(profile.opts, [:ml, :python_executable]) == "/tmp/hindsight-venv/bin/python3"
    assert get_in(profile.opts, [:ml, :python_worker_name]) == Foresight.ML.PythonLocalWorker
  end

  test "build/1 leaves the atomic-fact pipeline OFF by default (no extraction env)" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_LLM_BASE_URL" => "http://127.0.0.1:1234/v1",
        "FORESIGHT_LLM_MODEL" => "reader-model"
      })

    assert profile.engine_config.retain_extraction_mode == nil
    assert profile.engine_config.retain_extraction_provider_opts == nil
    assert profile.engine_config.consolidation_provider_opts == nil
  end

  test "build/1 wires the atomic-fact pipeline from env (mode + JSON model distinct from reader)" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_LLM_BASE_URL" => "http://gpu-host.local:11434/v1",
        "FORESIGHT_LLM_API_KEY" => "x",
        "FORESIGHT_LLM_MODEL" => "gpt-oss:20b",
        "FORESIGHT_RETAIN_EXTRACTION_MODE" => "verbatim",
        "FORESIGHT_RETAIN_EXTRACTION_DEADLINE_MS" => "120000",
        "FORESIGHT_RETAIN_EXTRACTION_CONCURRENCY" => "3",
        "FORESIGHT_JSON_LLM_MODEL" => "qwen3-coder:30b"
      })

    # reader/reflect stays the ANSWER model
    assert profile.engine_config.provider_opts[:model] == "gpt-oss:20b"

    # extraction wall-clock budget and chunk fan-out ride the same env surface
    assert profile.engine_config.retain_extraction_deadline_ms == 120_000
    assert profile.engine_config.retain_extraction_concurrency == 3

    # extraction + consolidation target the JSON model, inheriting the reader's
    # endpoint/key by default
    assert profile.engine_config.retain_extraction_mode == "verbatim"
    ex = profile.engine_config.retain_extraction_provider_opts
    assert ex[:model] == "qwen3-coder:30b"
    assert ex[:base_url] == "http://gpu-host.local:11434/v1"
    assert ex[:api_key] == "x"
    assert profile.engine_config.consolidation_provider_opts == ex
  end

  test "build/1 lets the JSON model use its own endpoint/key" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_LLM_BASE_URL" => "http://reader-host:11434/v1",
        "FORESIGHT_JSON_LLM_MODEL" => "qwen3-coder:30b",
        "FORESIGHT_JSON_LLM_BASE_URL" => "http://json-host:11434/v1",
        "FORESIGHT_JSON_LLM_API_KEY" => "json-key"
      })

    ex = profile.engine_config.retain_extraction_provider_opts
    assert ex[:base_url] == "http://json-host:11434/v1"
    assert ex[:api_key] == "json-key"

    # unset: no deadline, sequential chunks — the previous behaviour
    assert is_nil(profile.engine_config.retain_extraction_deadline_ms)
    assert profile.engine_config.retain_extraction_concurrency == 1
  end

  test "build/1 carries optional local ML batch tuning knobs through profile config" do
    profile =
      Foresight.Profiles.FullMLAuthority.build(%{
        "FORESIGHT_FILE_INGESTION" => "0",
        "FORESIGHT_EMBEDDING_BATCH_SIZE" => "8",
        "FORESIGHT_EMBEDDING_SEQUENCE_LENGTH" => "256",
        "FORESIGHT_RERANKER_BATCH_SIZE" => "16",
        "FORESIGHT_RERANKER_SEQUENCE_LENGTH" => "192"
      })

    assert get_in(profile.opts, [:ml, :batch_size]) == 8
    assert get_in(profile.opts, [:ml, :sequence_length]) == 256
    assert get_in(profile.opts, [:ml, :reranker_batch_size]) == 16
    assert get_in(profile.opts, [:ml, :reranker_sequence_length]) == 192
  end
end
