defmodule Foresight.Fitness.NamespacePurityTest do
  use ExUnit.Case, async: true

  alias Foresight.Fitness.NamespacePurity

  test "current engine tree has no adapter dependency leaks outside allowed namespaces" do
    assert NamespacePurity.violations() == []
  end

  test "planted violations are detected" do
    violations =
      NamespacePurity.violations_for_sources([
        {"lib/foresight/storage/example.ex",
         "defmodule Example do\n  Nx.Serving.batched_run(:x, [])\nend"}
      ])

    assert [%{file: "lib/foresight/storage/example.ex", refs: refs}] = violations
    assert "Nx" in refs
  end
end
