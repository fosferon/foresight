defmodule Foresight.Fitness.TenancyBoundaryTest do
  use ExUnit.Case, async: true

  alias Foresight.Fitness.TenancyBoundary

  test "current storage boundary keeps ctx-scoped repo functions behind role wrappers" do
    assert TenancyBoundary.violations() == []
  end

  test "planted tenant-scoped repo leaks are detected" do
    violations =
      TenancyBoundary.violations_for_sources([
        {"lib/foresight/storage/example.ex",
         """
         defmodule Example do
           def leak(ctx, repo) do
             repo.all([], tenant_repo_opts(ctx))
           end
         end
         """}
      ])

    assert [%{file: "lib/foresight/storage/example.ex", function: :leak}] = violations
  end
end
