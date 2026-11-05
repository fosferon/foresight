defmodule Foresight.EntityExtractorTest do
  @moduledoc """
  The seam dispatcher. `run/3` passes opts to an extractor that implements
  the optional `extract/2` (e.g. the LLM extractor, which needs an `:llm` handle) and
  otherwise calls the pure `extract/1` (the regex `Simple`). Mirrors the codebase's
  `function_exported?`-based optional-callback dispatch (`LLM.supports_tool_calling?`).
  """
  use ExUnit.Case, async: true

  alias Foresight.EntityExtractor

  defmodule Arity1 do
    @behaviour Foresight.EntityExtractor
    @impl true
    def extract(_content), do: ["one"]
  end

  defmodule Arity2 do
    @behaviour Foresight.EntityExtractor
    @impl true
    def extract(_content), do: ["one"]
    @impl true
    def extract(_content, opts), do: ["two", to_string(Keyword.get(opts, :marker))]
  end

  test "run/3 dispatches to extract/2 when the extractor exports it, passing opts" do
    assert EntityExtractor.run(Arity2, "x", marker: :ok) == ["two", "ok"]
  end

  test "run/3 falls back to extract/1 when extract/2 is absent (opts ignored)" do
    assert EntityExtractor.run(Arity1, "x", marker: :ignored) == ["one"]
  end

  test "run/2 defaults opts to [] and still dispatches" do
    assert EntityExtractor.run(Arity1, "x") == ["one"]
    assert EntityExtractor.run(Arity2, "x") == ["two", ""]
  end
end
