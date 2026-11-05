defmodule Foresight.Fitness.NamespacePurity do
  @moduledoc false

  @engine_root Path.expand("../..", __DIR__)
  @allowed_prefixes [
    "lib/foresight/http/",
    "lib/foresight/ml/",
    "lib/foresight/embedders/",
    "lib/foresight/rerankers/",
    "lib/foresight/llms/"
  ]
  @banned_refs ~w(Bandit Plug Nx Bumblebee LlmCore Exla Ortex ErlPort)

  @type violation :: %{file: String.t(), refs: [String.t()]}

  @spec violations() :: [violation()]
  def violations do
    @engine_root
    |> Path.join("lib/foresight/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&allowed_file?/1)
    |> Enum.map(&source_violation/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec violations_for_sources([{String.t(), String.t()}]) :: [violation()]
  def violations_for_sources(sources) do
    sources
    |> Enum.map(fn {file, source} -> source_violation(file, source) end)
    |> Enum.reject(&is_nil/1)
  end

  defp allowed_file?(file) do
    relative = Path.relative_to(file, @engine_root)
    Enum.any?(@allowed_prefixes, &String.starts_with?(relative, &1))
  end

  defp source_violation(file) do
    source_violation(file, File.read!(file))
  end

  defp source_violation(file, source) do
    refs =
      @banned_refs
      |> Enum.filter(&String.contains?(source, &1))

    if refs == [] do
      nil
    else
      %{file: file, refs: refs}
    end
  end
end
