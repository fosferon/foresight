defmodule Mix.Tasks.Foresight.IsolationCoverage do
  use Mix.Task

  alias Foresight.Fitness.IsolationCoverage

  @shortdoc "Fails when the Mode C isolation probes are excluded from the default test lane"

  @impl true
  def run(_args) do
    case IsolationCoverage.violations() do
      [] ->
        Mix.shell().info("isolation coverage check passed")

      violations ->
        formatted =
          Enum.map_join(violations, "\n", fn %{file: file, reason: reason} ->
            "#{Path.relative_to_cwd(file)} -> #{reason}"
          end)

        Mix.raise("""
        isolation coverage check failed

        #{formatted}
        """)
    end
  end
end
