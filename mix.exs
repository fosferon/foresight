defmodule Foresight.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/fosferon/foresight"

  def project do
    [
      app: :foresight,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      # Optional dependencies: a consumer that omits them must not see
      # "module is undefined" warnings for the code paths that need them.
      xref: [
        exclude: [
          Bumblebee,
          Bumblebee.Text,
          Nx.Serving,
          Tokenizers.Tokenizer,
          Tokenizers.Encoding,
          LlmCore.Agent.Loop,
          :python
        ]
      ],
      name: "Foresight",
      description:
        "Semantic memory for Elixir — retain, recall, reflect. An Elixir port of " <>
          "Vectorize's Hindsight (MIT), measured at statistical parity.",
      package: package(),
      docs: docs()
    ]
  end

  # The `files:` whitelist is the important line. Without it hex ships the entire
  # working tree — which here includes internal audit reports and cutover dossiers
  # written for private consumers. Whitelist, never blacklist: a new internal doc
  # should be excluded by default rather than published by default.
  # The hex package is `foresight_memory`; the OTP app stays `:foresight`. The plain
  # name is taken on hex by an unrelated, live package (a URL-preview web crawler,
  # ~80 downloads/week), so it is not available and not worth contesting. Nothing else
  # changes: modules, the app name, and `alias Foresight` are all untouched.
  #
  # Consumers therefore write:
  #     {:foresight, "~> 0.1", hex: :foresight_memory}
  # The `hex:` option is how Mix resolves a dependency whose package name differs from
  # its application name.
  defp package do
    [
      name: "foresight_memory",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Hindsight (upstream)" => "https://github.com/vectorize-io/hindsight"
      },
      # priv is enumerated, NOT taken wholesale. priv/evals/data holds 279MB of
      # benchmark corpora — evaluation inputs, not library assets — which pushed the
      # tarball past hex's 134MB uncompressed ceiling and would have shipped a
      # third of a gigabyte of test fixtures to every consumer.
      # `DEVELOPMENT.md` (local qualification workflows) stays out of the tarball
      # deliberately: it is repository material, not consumer material.
      files:
        ~w(lib mix.exs README.md READINESS.md LICENSE CHANGELOG.md guides .formatter.exs) ++
          ~w(priv/repo/migrations priv/foresight priv/python),
      # `files:` matches the working tree, not git, so untracked local artifacts
      # under the whitelisted dirs would otherwise ship: __pycache__ bytecode from
      # a local sentence-transformers run is the known offender.
      # NOTE: hex (2.4.x) matches these as regexes against the relative path,
      # not as file globs — despite the option name.
      exclude_patterns: ["__pycache__", "\\.pyc$"]
    ]
  end

  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      source_url: @source_url,
      # Ordered as a manual, not as a file listing: what it is, then the decision the
      # reader has to make first, then the two subjects that actually surprise people,
      # then operations.
      extras: [
        "guides/overview.md",
        "READINESS.md",
        "guides/getting-started.md",
        "guides/choosing-a-surface.md",
        "guides/how-recall-works.md",
        "guides/reflect.md",
        "guides/multi-tenancy.md",
        "guides/mode-c-least-privilege.md",
        "guides/evaluation.md",
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Introduction: ~r/guides\/(overview|getting-started|choosing-a-surface)/,
        "How it works": ~r/guides\/(how-recall-works|reflect)/,
        Operating: ~r/guides\/(multi-tenancy|mode-c-least-privilege|evaluation)/,
        Readiness: ~r/(READINESS|CHANGELOG)\.md$/
      ],
      groups_for_modules: [
        "Public API": [
          Foresight,
          Foresight.Supervisor,
          Foresight.Context,
          Foresight.Error,
          Foresight.Migrations,
          Foresight.Migrations.Manifest,
          Foresight.Tenancy
        ],
        Behaviours: [
          Foresight.Backend,
          Foresight.Embedder,
          Foresight.Reranker,
          Foresight.LLM,
          Foresight.AsyncQueue
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :xmerl],
      mod: {Foresight.Application, []}
    ]
  end

  # `mix ci` ends in `test`, so the whole alias has to run in :test. Without this,
  # a bare `mix ci` runs in :dev and dies at the last step ("mix test is running in
  # the dev environment") after every other gate has already passed — the one
  # command a new consumer is told to run could never succeed.
  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "foresight.namespace_purity",
        "foresight.tenancy_boundary",
        "foresight.isolation_coverage",
        "test"
      ]
    ]
  end

  defp deps do
    # Version floors are the lines the suite actually runs against (see mix.lock):
    # pre-1.0 deps use three-segment ~> because their minors break; stable 1.x
    # deps admit later minors. Loosen a floor deliberately, never silently.
    [
      {:bandit, "~> 1.11", optional: true},
      {:bumblebee, "~> 0.7.0", optional: true},
      {:ecto_sql, "~> 3.13"},
      {:erlport, "~> 0.11.0", optional: true},
      {:exla, "~> 0.12.0", optional: true},
      {:jason, "~> 1.4"},
      {:hermes_mcp, "~> 0.14.0", optional: true},
      # >= 0.4.4 required: earlier versions drop assistant tool_calls during
      # message serialization, aborting the agentic reflect loop.
      # Genuinely optional: it is a heavy tree (alf, comm_bus, yaml_elixir, file_system,
      # toml, ...) and starts a Hindsight discovery monitor at boot, so a consumer that
      # brings its own LLM should not have to carry it.
      {:llm_core, "~> 0.5.0", optional: true},
      # NOT optional, deliberately. Foresight pattern-matches %LlmToolkit.Tool.Call{}
      # in the reflect tool dispatch and builds %LlmToolkit.Tool{} structs in the prompt
      # module — both compile-time references, so declaring it optional made `mix compile`
      # fail outright for any consumer rather than degrading. It is nearly free here: its
      # only deps are req and ecto, which this library already carries.
      {:llm_toolkit, "~> 0.1.0"},
      {:nx, "~> 0.12.0", optional: true},
      {:oban, "~> 2.23"},
      {:ortex, "~> 0.1.10", optional: true},
      {:pgvector, "~> 0.3.0"},
      # NOT optional, deliberately. Nineteen modules `import Plug.Conn` /
      # `use Plug.Router` unconditionally, so "optional" was never true — a consumer
      # omitting it got a CompileError, not an absent HTTP surface. The honest choices
      # were to guard nineteen modules with Code.ensure_loaded? or to admit the dep;
      # plug is small and pure Elixir, so carrying it beats nineteen conditionals.
      {:plug, "~> 1.20"},
      {:postgrex, "~> 0.19 or ~> 1.0"},
      {:tokenizers, "~> 0.5.0", optional: true},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
