defmodule Mix.Tasks.Foresight.NamespacePurity do
  use Mix.Task

  alias Foresight.Fitness.NamespacePurity

  @shortdoc "Fails when engine modules reference optional adapter deps outside adapter namespaces"

  @impl true
  def run(_args) do
    case NamespacePurity.violations() do
      [] ->
        Mix.shell().info("namespace purity check passed")

      violations ->
        formatted =
          Enum.map_join(violations, "\n", fn %{file: file, refs: refs} ->
            "#{Path.relative_to_cwd(file)} -> #{Enum.join(refs, ", ")}"
          end)

        Mix.raise("""
        namespace purity check failed

        #{formatted}
        """)
    end
  end
end
