defmodule Foresight.Reflect.EntailmentVerifiers.LLMJudgeTest do
  @moduledoc """
  LLM-judge entailment verifier: one structured call returns which clauses
  the cited evidence supports. Degrades to all-supported on an absent/incapable/erroring
  LLM — a broken verifier must never block a reflect answer.
  """
  use ExUnit.Case, async: true

  alias Foresight.Reflect.EntailmentVerifiers.LLMJudge

  # Marks clause index 1 unsupported, the rest supported (echoes back by index).
  defmodule VerdictLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_p, _m, _s, _o) do
      {:ok,
       %{
         "verdicts" => [
           %{"index" => 0, "supported" => true},
           %{"index" => 1, "supported" => false},
           %{"index" => 2, "supported" => true}
         ]
       }}
    end

    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  # Omits index 2 entirely — the judge must default a missing verdict to supported.
  defmodule PartialLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_p, _m, _s, _o),
      do: {:ok, %{"verdicts" => [%{"index" => 0, "supported" => false}]}}

    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  defmodule ErrorLLM do
    @behaviour Foresight.LLM
    @impl true
    def complete_json_schema(_p, _m, _s, _o), do: {:error, {:boom, "body"}}
    @impl true
    def complete_structured(_p, _m, _mod, _o), do: {:error, :unused}
  end

  defmodule NotAnLLM do
    def hi, do: :ok
  end

  @clauses ["Alice joined", "Bob left", "Carol stayed"]
  @evidence ["Alice joined in March", "Carol stayed on"]

  test "returns the LLM's per-clause verdicts, in clause order" do
    verdicts = LLMJudge.verify(@clauses, @evidence, llm: VerdictLLM)
    assert Enum.map(verdicts, & &1.clause) == @clauses
    assert Enum.map(verdicts, & &1.supported?) == [true, false, true]
    assert Enum.map(verdicts, & &1.score) == [1.0, 0.0, 1.0]
  end

  test "a clause the LLM omits defaults to supported (degrade-safe)" do
    verdicts = LLMJudge.verify(@clauses, @evidence, llm: PartialLLM)
    assert Enum.map(verdicts, & &1.supported?) == [false, true, true]
  end

  test "degrades to all-supported on an LLM error" do
    verdicts = LLMJudge.verify(@clauses, @evidence, llm: ErrorLLM)
    assert Enum.all?(verdicts, & &1.supported?)
    assert Enum.map(verdicts, & &1.clause) == @clauses
  end

  test "degrades to all-supported on an incapable/absent LLM" do
    assert Enum.all?(LLMJudge.verify(@clauses, @evidence, llm: NotAnLLM), & &1.supported?)
    assert Enum.all?(LLMJudge.verify(@clauses, @evidence, llm: nil), & &1.supported?)
    assert Enum.all?(LLMJudge.verify(@clauses, @evidence, []), & &1.supported?)
  end

  test "empty clauses → empty verdicts (no LLM call needed)" do
    assert LLMJudge.verify([], @evidence, llm: VerdictLLM) == []
  end
end
