defmodule Foresight.EntityExtractors.LLMTest do
  @moduledoc """
  LLM-backed fallback extractor. Used only when retain-time
  atomic-fact extraction is OFF so items carry no `fact.entities`. Asserts it returns
  the LLM's entity names, tolerates the `{name/text => ...}` object shape, RESPECTS a
  competent empty result (does not backfill regex noise), and DEGRADES to the regex
  `Simple` on an incapable/absent/erroring LLM — extraction never fails retain.
  """
  use ExUnit.Case, async: true

  alias Foresight.EntityExtractors.LLM
  alias Foresight.EntityExtractors.Simple

  # A capable LLM returning bare-string entities (with dupes + whitespace to prove
  # normalisation).
  defmodule FixedLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:ok, %{"entities" => ["Alice", "Kubernetes", "Kubernetes", "  CKA  "]}}

    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  # A capable LLM returning the {name/text => ...} object shape.
  defmodule ObjectLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:ok, %{"entities" => [%{"name" => "Emily"}, %{"text" => "Sarah"}, %{"nope" => "x"}]}}

    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  # A capable LLM that competently finds no entities.
  defmodule EmptyLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:ok, %{"entities" => []}}

    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  # A capable LLM that errors.
  defmodule ErrorLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:error, {:boom, "unrecoverable body"}}

    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  # Not an LLM at all — no complete_json_schema/4.
  defmodule NotAnLLM do
    def hello, do: :world
  end

  @content "Alice has 5 years Kubernetes experience and is CKA certified."

  test "returns the LLM's entity names, trimmed and de-duplicated" do
    assert LLM.extract(@content, llm: FixedLLM) == ["Alice", "Kubernetes", "CKA"]
  end

  test "tolerates {name/text => ...} object items and drops shapeless ones" do
    assert LLM.extract(@content, llm: ObjectLLM) == ["Emily", "Sarah"]
  end

  test "respects a competent empty result — does NOT backfill regex noise" do
    # @content has capitalized words Simple WOULD extract; prove we return [] instead.
    refute Simple.extract(@content) == []
    assert LLM.extract(@content, llm: EmptyLLM) == []
  end

  test "degrades to Simple on an LLM error" do
    assert LLM.extract(@content, llm: ErrorLLM) == Simple.extract(@content)
  end

  test "degrades to Simple when the llm is incapable (no complete_json_schema/4)" do
    assert LLM.extract(@content, llm: NotAnLLM) == Simple.extract(@content)
  end

  test "degrades to Simple when no llm is supplied (nil / extract/1)" do
    assert LLM.extract(@content, llm: nil) == Simple.extract(@content)
    assert LLM.extract(@content, []) == Simple.extract(@content)
    assert LLM.extract(@content) == Simple.extract(@content)
  end
end
