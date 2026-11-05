defmodule Foresight.ConfigTest do
  use ExUnit.Case

  test "merges application config with runtime overrides" do
    config = Foresight.Config.resolve(http: [enabled: true], repo: [enabled: true])

    assert config.http.enabled
    assert config.repo.enabled
    refute config.tenancy.rls_enabled
    refute config.file_ingestion.enabled
    refute config.ml.enabled
  end

  test "resolve/1 falls back to defaults when a section is left nil in the app env" do
    # Reproduces the cross-test poisoning where a test restored an originally-unset
    # section via put_env(:foresight, :tenancy, nil), leaving the key present-but-nil.
    # resolve/1 must ignore the nil section and use its default map, not blow it away.
    original = Application.get_env(:foresight, :tenancy)
    Application.put_env(:foresight, :tenancy, nil)
    on_exit(fn -> restore(:tenancy, original) end)

    config = Foresight.Config.resolve()

    assert is_map(config.tenancy)
    refute config.tenancy.rls_enabled
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)

  test "passes preflight when enabled capabilities are installed" do
    assert :ok =
             Foresight.Config.preflight!(%{
               auth: %{request_api_key: "test-service-key"},
               file_ingestion: %{enabled: false},
               http: %{enabled: true},
               ml: %{enabled: false},
               oban: %{enabled: true},
               repo: %{enabled: true}
             })
  end

  test "passes preflight when the dedicated public repo is enabled without the main repo" do
    assert :ok =
             Foresight.Config.preflight!(%{
               file_ingestion: %{enabled: false},
               http: %{enabled: false},
               ml: %{enabled: false},
               oban: %{enabled: false},
               repo: %{enabled: false, public: %{enabled: true}}
             })
  end

  test "passes preflight for a hybrid remote-llm profile without local ml servings" do
    assert :ok =
             Foresight.Config.preflight!(%{
               file_ingestion: %{enabled: false},
               http: %{enabled: true},
               ml: %{enabled: false},
               oban: %{enabled: false},
               repo: %{enabled: true},
               auth: %{request_api_key: "test-service-key"},
               engine: %{
                 embedder: Foresight.Embedders.Noop,
                 reranker: Foresight.Rerankers.Passthrough,
                 llm: Foresight.LLMs.LlmCore,
                 provider: "openai"
               }
             })
  end

  test "still passes preflight for local bumblebee paths when optional ml deps are installed" do
    assert :ok =
             Foresight.Config.preflight!(%{
               file_ingestion: %{enabled: false},
               http: %{enabled: true},
               ml: %{enabled: false},
               oban: %{enabled: false},
               repo: %{enabled: true},
               auth: %{request_api_key: "test-service-key"},
               engine: %{
                 embedder: Foresight.Embedders.Bumblebee,
                 reranker: Foresight.Rerankers.Bumblebee
               }
             })
  end

  test "fails preflight when file ingestion python executable is missing" do
    assert_raise RuntimeError,
                 ~r/file ingestion is enabled but the configured Python executable/,
                 fn ->
                   Foresight.Config.preflight!(%{
                     file_ingestion: %{
                       enabled: true,
                       python_executable: "/definitely/missing/python3"
                     },
                     http: %{enabled: false},
                     ml: %{enabled: false},
                     oban: %{enabled: false},
                     repo: %{enabled: false}
                   })
                 end
  end

  test "fails preflight when mcp is enabled without http" do
    assert_raise RuntimeError, ~r/MCP is enabled but HTTP is disabled/, fn ->
      Foresight.Config.preflight!(%{
        file_ingestion: %{enabled: false},
        http: %{enabled: false},
        mcp: %{enabled: true, registry: Hermes.Server.Registry, server: Foresight.MCP.Server},
        ml: %{enabled: false},
        oban: %{enabled: false},
        repo: %{enabled: false}
      })
    end
  end

  test "fails preflight when configured python cannot import docling" do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "foresight-docling-preflight-fail-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(
      script_path,
      "#!/bin/sh\necho 'ModuleNotFoundError: no module named docling' >&2\nexit 1\n"
    )

    File.chmod!(script_path, 0o755)

    on_exit(fn -> File.rm(script_path) end)

    assert_raise RuntimeError, ~r/Docling is unavailable/, fn ->
      Foresight.Config.preflight!(%{
        file_ingestion: %{enabled: true, python_executable: script_path},
        http: %{enabled: false},
        ml: %{enabled: false},
        oban: %{enabled: false},
        repo: %{enabled: false}
      })
    end
  end

  test "passes preflight when configured python can import docling" do
    script_path =
      Path.join(
        System.tmp_dir!(),
        "foresight-docling-preflight-pass-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(script_path, "#!/bin/sh\nexit 0\n")
    File.chmod!(script_path, 0o755)

    on_exit(fn -> File.rm(script_path) end)

    assert :ok =
             Foresight.Config.preflight!(%{
               file_ingestion: %{enabled: true, python_executable: script_path},
               http: %{enabled: false},
               ml: %{enabled: false},
               oban: %{enabled: false},
               repo: %{enabled: false}
             })
  end

  test "defaults to the neural reranker and allows explicit passthrough fallback override" do
    default_config = Foresight.Config.resolve()

    fallback_config =
      Foresight.Config.resolve(engine: [reranker: Foresight.Rerankers.Passthrough])

    assert default_config.engine.reranker == Foresight.Rerankers.Bumblebee
    assert default_config.engine.reflect_timeout_ms == 120_000
    assert fallback_config.engine.reranker == Foresight.Rerankers.Passthrough
  end
end
