defmodule Mix.Tasks.Foresight.TenancyBoundary do
  use Mix.Task

  alias Foresight.Fitness.TenancyBoundary

  @shortdoc "Fails when tenant-scoped storage functions bypass the Mode C role wrapper"

  @impl true
  def run(_args) do
    case TenancyBoundary.violations() do
      [] ->
        Mix.shell().info("tenancy boundary check passed")

      violations ->
        formatted =
          Enum.map_join(violations, "\n", fn %{file: file, function: function, reason: reason} ->
            "#{Path.relative_to_cwd(file)}##{function} -> #{reason}"
          end)

        Mix.raise("""
        tenancy boundary check failed

        #{formatted}
        """)
    end
  end
end
