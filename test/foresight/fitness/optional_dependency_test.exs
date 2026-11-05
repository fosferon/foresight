defmodule Foresight.Fitness.OptionalDependencyTest do
  @moduledoc """
  Guards the one property nobody notices until a stranger tries the library: a dependency
  declared `optional: true` must actually be optional.

  `:plug` and `:llm_core` were declared optional while being referenced
  unconditionally at compile time, so `{:foresight, ...}` on its own failed `mix compile`
  with a CompileError. Not a degraded feature — the whole library refused to build, on
  the surface READINESS.md recommends first. It survived months because every developer
  checkout has all the optional deps installed, so the failure is invisible from inside
  the repo.

  These tests read mix.exs and the source tree rather than compiling a throwaway project,
  because a full consumer build takes minutes and this needs to run in the default lane.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  # Modules whose whole point is to adapt an optional dependency. They are allowed to
  # reference it, provided they are wrapped in a Code.ensure_loaded? guard with a
  # fallback — the Foresight.MCP.Server pattern.
  @guarded_adapters [
    "lib/foresight/mcp/server.ex",
    "lib/foresight/mcp/accept_plug.ex",
    "lib/foresight/llms/llm_core.ex"
  ]

  defp optional_deps do
    mix_exs = File.read!(Path.join(@root, "mix.exs"))

    ~r/\{:([a-z_]+),[^}]*optional:\s*true/
    |> Regex.scan(mix_exs)
    |> Enum.map(fn [_, dep] -> dep end)
  end

  defp source_files do
    @root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&{Path.relative_to(&1, @root), File.read!(&1)})
  end

  # A struct literal, `import`, or `use` of a module is resolved at compile time. An atom
  # like :"Elixir.LlmCore.LLM.Native", or a match on %{__struct__: @mod}, is not — those
  # are the escape hatches this codebase already uses correctly.
  #
  # `alias` is included, and that is the whole point. The first version of this test
  # looked only for %LlmCore.X{} and so missed the exact defect it was written for:
  # `alias LlmCore.LLM.Error, as: LlmError` renames the struct, and `%LlmError{}` is
  # then invisible to any pattern naming the dependency. A bare alias is not itself a
  # compile-time dependency, but it exists in order to be used, and its uses cannot be
  # found textually — so the alias is the thing worth banning.
  # Full-line comments are stripped first. Without this the detector fires on its own
  # documentation: lib/foresight/llms/llm_core.ex explains the guard by NAMING
  # %LlmCore.LLM.Response{} in a comment, and that was reported as a violation. Only
  # whole-line comments are removed, so `alias LlmCore.X # note` still gets caught.
  defp compile_time_refs(source, module_prefix) do
    source =
      source
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
      |> Enum.join("\n")

    patterns = [
      # struct literal, fully qualified
      ~r/%#{module_prefix}\.[A-Za-z0-9_.]*\{/,
      # the aliasing forms — each binds the module name at compile time
      ~r/^\s*alias\s+#{module_prefix}\b/m,
      ~r/^\s*import\s+#{module_prefix}\b/m,
      ~r/^\s*use\s+#{module_prefix}\b/m,
      # require and @behaviour are compile-time resolved too (audit Finding 3)
      ~r/^\s*require\s+#{module_prefix}\b/m,
      ~r/^\s*@behaviour\s+#{module_prefix}\b/m,
      # a typespec naming the module needs it present to compile
      ~r/^\s*@(?:spec|type|callback|opaque)\s+.*#{module_prefix}\./m,
      # struct/2 and struct!/2 with a literal module expand at compile time
      ~r/struct!?\(\s*#{module_prefix}\./
    ]

    Enum.filter(patterns, &Regex.match?(&1, source))
  end

  # Every optional dep, not a hand-picked three. The three-prefix version would have
  # stayed green if someone added an unguarded `use Bandit...` tomorrow (audit Finding 3).
  @dep_prefixes %{
    "plug" => "Plug",
    "llm_core" => "LlmCore",
    "hermes_mcp" => "Hermes",
    "bandit" => "Bandit",
    "bumblebee" => "Bumblebee",
    "nx" => "Nx",
    "exla" => "EXLA",
    "ortex" => "Ortex",
    "erlport" => "ErlPort",
    "tokenizers" => "Tokenizers"
  }

  defp guarded?(source), do: source =~ "Code.ensure_loaded?"

  test "mix.exs declares at least one optional dependency" do
    # If this fails the rest of the suite is vacuously green, which is exactly the
    # failure mode that let this bug live for months.
    refute Enum.empty?(optional_deps())
  end

  test "every optional dependency in mix.exs has a prefix this test knows how to check" do
    # Without this, adding a new optional dep silently widens the blind spot.
    unknown = optional_deps() -- Map.keys(@dep_prefixes)

    assert unknown == [],
           "optional deps with no module prefix registered in @dep_prefixes: #{inspect(unknown)}"
  end

  test "no module makes an unguarded compile-time reference to an optional dependency" do
    violations =
      for {dep, prefix} <- @dep_prefixes,
          dep in optional_deps(),
          {file, source} <- source_files(),
          file not in @guarded_adapters,
          not guarded?(source),
          compile_time_refs(source, prefix) != [],
          do: {file, dep}

    assert violations == [], """
    These modules reference an OPTIONAL dependency at compile time without a
    Code.ensure_loaded? guard, so a consumer who omits that dependency cannot compile
    Foresight at all:

    #{Enum.map_join(violations, "\n", fn {f, d} -> "  #{f}  (needs :#{d})" end)}

    Fix by one of:
      * make the dependency non-optional in mix.exs (right when it is small and
        broadly needed — this is what :plug and :llm_toolkit ended up doing);
      * wrap the module in `if Code.ensure_loaded?(Mod) do ... else <stub> end`
        (right for a dedicated adapter — see lib/foresight/mcp/server.ex);
      * refer to the module at RUNTIME instead — an atom like
        :"Elixir.LlmCore.LLM.Error", or matching %{__struct__: @mod} — which is what
        lib/foresight/http/error_translator.ex does.
    """
  end

  # The test above is only worth having if it fails on the real defect. This asserts the
  # detector itself, against the exact source shape that shipped the bug, so a future
  # narrowing of the regex breaks here rather than going quietly blind.
  test "the detector catches an ALIASED struct reference, not just a fully-qualified one" do
    aliased = """
    defmodule Fake do
      alias LlmCore.LLM.Error, as: LlmError
      def f(%LlmError{} = e), do: e
    end
    """

    qualified = "defmodule Fake do\n  def f(%LlmCore.LLM.Error{} = e), do: e\nend\n"
    runtime_safe = ~S|defmodule Fake do
      @m :"Elixir.LlmCore.LLM.Error"
      def f(%{__struct__: @m} = e), do: e
    end|

    refute compile_time_refs(aliased, "LlmCore") == [], "aliased struct reference not detected"

    refute compile_time_refs(qualified, "LlmCore") == [],
           "qualified struct reference not detected"

    assert compile_time_refs(runtime_safe, "LlmCore") == [],
           "runtime-safe reference wrongly flagged"
  end

  # Every form the audit listed (Finding 3), asserted directly against the detector.
  #
  # Deliberately a unit test rather than a mutation of lib/. I first tried proving these
  # by injecting each form into a real module and re-running the suite — and the @spec
  # injection referenced an undefined function, so the file would not COMPILE, the suite
  # never ran, zero failures were counted, and I read that as "the detector missed it".
  # A harness whose failure mode is indistinguishable from a pass is worse than no
  # harness. Feeding source strings straight to the function cannot fail that way.
  test "the detector recognises every compile-time reference form the audit named" do
    forms = [
      {"require", "defmodule F do\n  require LlmCore.LLM.Response\nend"},
      {"@behaviour", "defmodule F do\n  @behaviour LlmCore.LLM.Provider\nend"},
      {"@spec", "defmodule F do\n  @spec f() :: LlmCore.LLM.Response.t()\nend"},
      {"@type", "defmodule F do\n  @type t() :: LlmCore.LLM.Response.t()\nend"},
      {"@callback", "defmodule F do\n  @callback f() :: LlmCore.LLM.Response.t()\nend"},
      {"struct/2", "defmodule F do\n  def f, do: struct(LlmCore.LLM.Error, [])\nend"},
      {"struct!/2", "defmodule F do\n  def f, do: struct!(LlmCore.LLM.Error, [])\nend"},
      {"import", "defmodule F do\n  import LlmCore.LLM.Response\nend"},
      {"use", "defmodule F do\n  use LlmCore.LLM.Provider\nend"}
    ]

    missed =
      for {label, source} <- forms, compile_time_refs(source, "LlmCore") == [], do: label

    assert missed == [],
           "detector is blind to these compile-time forms: #{inspect(missed)}"
  end

  test "the detector does NOT flag references that are resolved at runtime" do
    # These are the sanctioned escape hatches. Flagging them would push people toward
    # the compile-time forms to silence the test, which is the opposite of the point.
    safe = [
      {"atom module", ~S|defmodule F do
         @m :"Elixir.LlmCore.LLM.Error"
         def f(%{__struct__: @m} = e), do: e
       end|},
      {"remote call on a variable", "defmodule F do\n  def f(m), do: m.complete([])\nend"},
      {"mention in a comment",
       "defmodule F do\n  # LlmCore.LLM.Response is optional\n  def f, do: :ok\nend"}
    ]

    flagged = for {label, source} <- safe, compile_time_refs(source, "LlmCore") != [], do: label

    assert flagged == [], "detector wrongly flags runtime-safe forms: #{inspect(flagged)}"
  end

  # Audit finding: The commit that "fixed" installability claimed a bare
  # consumer boots; it did not. The default reranker was Foresight.Rerankers.Bumblebee,
  # so preflight demanded :nx/:bumblebee/:exla/:ortex/:tokenizers and a consumer with
  # only Foresight's required deps failed to start. My smoke test passed solely because
  # it supplied a config overriding the reranker — it proved the CONFIGURED case and was
  # reported as the BARE case.
  #
  # This asserts the property directly against the default config, with no overrides.
  test "the DEFAULT config requires no optional dependency" do
    # Foresight.Config.resolve/1 merges application env over the code defaults, and THIS
    # repo's own config/config.exs sets reranker: Bumblebee for its dev/test lanes. A
    # consumer never loads a dependency's config/config.exs, so asserting on resolve([])
    # as-is would measure our own dev config and prove nothing about them. Clear the app
    # env for the duration to get what a consumer actually gets.
    #
    # (I got this wrong first time and the test failed for the right reason — it was
    # reading Bumblebee out of our own config while claiming to read the shipped default.)
    saved =
      for k <- [:engine, :http, :mcp, :repo, :oban, :file_ingestion, :ml],
          do: {k, Application.fetch_env(:foresight, k)}

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, value} -> Application.put_env(:foresight, k, value)
          :error -> Application.delete_env(:foresight, k)
        end
      end
    end)

    for {k, _} <- saved, do: Application.delete_env(:foresight, k)

    required = Foresight.Config.resolve([]) |> required_optional_apps_for_test()

    assert required == [],
           """
           The shipped defaults demand optional dependencies: #{inspect(required)}

           A consumer who adds {:foresight, ...} and writes no config at all must be able
           to boot. Every entry here is a dependency they would have to discover and
           install before the library starts.
           """
  end

  # Mirrors Foresight.Config.required_optional_apps/1, which is private. Kept deliberately
  # simple: if this drifts from the real preflight the boot test below catches it, because
  # that one starts an actual supervisor.
  defp required_optional_apps_for_test(config) do
    ml =
      [get_in(config, [:engine, :embedder]), get_in(config, [:engine, :reranker])]
      |> Enum.filter(&(&1 in [Foresight.Embedders.Bumblebee, Foresight.Rerankers.Bumblebee]))

    []
    |> then(&if get_in(config, [:http, :enabled]), do: &1 ++ [:bandit], else: &1)
    |> then(&if get_in(config, [:mcp, :enabled]), do: &1 ++ [:hermes_mcp], else: &1)
    |> then(&if get_in(config, [:repo, :enabled]), do: &1 ++ [:ecto_sql], else: &1)
    |> then(&if get_in(config, [:oban, :enabled]), do: &1 ++ [:oban], else: &1)
    |> then(&if ml != [], do: &1 ++ [:nx, :bumblebee], else: &1)
  end

  test "a supervisor starts under the DEFAULT config, with nothing configured" do
    # The end-to-end version of the test above: no config, no overrides, real preflight.
    assert {:ok, pid} =
             Foresight.Supervisor.start_link(name: :"bare-#{System.unique_integer([:positive])}")

    assert is_pid(pid)
    Supervisor.stop(pid)
  end

  # Audit Finding 4: @guarded_adapters exempts a file wholesale, so an `alias LlmCore...`
  # added ABOVE the guard would be invisible. Everything before `if Code.ensure_loaded?`
  # is evaluated unconditionally, so that prefix must be clean.
  test "guarded adapters have no compile-time reference ABOVE their guard" do
    violations =
      for file <- @guarded_adapters,
          source = File.read!(Path.join(@root, file)),
          [preamble | _] = String.split(source, ~r/^if Code\.ensure_loaded\?/m, parts: 2),
          {_dep, prefix} <- @dep_prefixes,
          compile_time_refs(preamble, prefix) != [],
          do: {file, prefix}

    assert violations == [], """
    These guarded adapters reference an optional dependency before the guard, where it
    is evaluated unconditionally — the guard below it is decorative:

    #{Enum.map_join(violations, "\n", fn {f, p} -> "  #{f}  (#{p})" end)}
    """
  end

  test "every guarded adapter has a fallback, not just a guard" do
    # A guard with no else-branch turns a missing dependency into an undefined-function
    # error at the call site, which is harder to diagnose than the compile error it
    # replaced. Each adapter must define the module either way.
    for file <- @guarded_adapters do
      source = File.read!(Path.join(@root, file))

      assert source =~ "Code.ensure_loaded?", "#{file} is listed as guarded but has no guard"
      assert source =~ ~r/^\s*else\s*$/m, "#{file} guards without a fallback definition"
    end
  end
end
