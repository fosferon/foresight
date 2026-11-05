defmodule Foresight.Fitness.IsolationCoverageTest do
  @moduledoc """
  Note: guards the guard. The Mode C isolation probes are the continuous proof that the
  cross-tenant escape stays closed, and they were excluded from the default lane by
  a single `@moduletag :tier2` line — asserted but never run.
  """
  use ExUnit.Case, async: true

  alias Foresight.Fitness.IsolationCoverage

  @tmp Path.join(System.tmp_dir!(), "foresight-isolation-coverage-test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  test "the real isolation suite runs in the default lane" do
    assert IsolationCoverage.violations() == []
  end

  test "flags a probe tagged with anything the default lane excludes" do
    for tag <- ["tier2", "nightly", "ml"] do
      source = """
      defmodule Probe do
        use ExUnit.Case
        @moduletag :#{tag}
      end
      """

      assert [%{reason: reason}] =
               IsolationCoverage.violations_for_source("probe_test.exs", source)

      assert reason =~ ":#{tag}"
      assert reason =~ "skipped"
    end
  end

  # Audit finding: the original regex only matched the bare-atom form, so any of these
  # would have silently re-excluded the isolation suite.
  test "flags every tag form ExUnit accepts, not just the bare atom" do
    for form <- [
          "@moduletag :tier2",
          "@moduletag [:tier2, :nightly]",
          "@moduletag tier2: true",
          "@moduletag [tier2: true]",
          "@tag [tier2: true]"
        ] do
      source = "defmodule Probe do\n  #{form}\nend\n"

      assert [%{reason: reason} | _] =
               IsolationCoverage.violations_for_source("probe_test.exs", source),
             "form #{form} was not flagged"

      assert reason =~ ":tier2"
    end
  end

  test "flags a per-test tag as well as a module tag" do
    source = """
    defmodule Probe do
      @tag :tier2
      test "isolated" do
      end
    end
    """

    assert [%{reason: reason}] = IsolationCoverage.violations_for_source("probe_test.exs", source)
    assert reason =~ ":tier2"
  end

  test "an ungated probe is clean" do
    source = """
    defmodule Probe do
      use ExUnit.Case
      test "isolated" do
      end
    end
    """

    assert IsolationCoverage.violations_for_source("probe_test.exs", source) == []
  end

  test "an empty isolation directory is itself a violation, not a pass" do
    # Deleting the probes must not read as "no violations found".
    assert [%{reason: reason}] = IsolationCoverage.violations_for_dir(@tmp)
    assert reason =~ "no isolation probe tests found"
  end
end
