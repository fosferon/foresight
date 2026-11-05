defmodule Foresight.Reflect.EntailmentGateTest do
  @moduledoc """
  The backend-agnostic grounding gate. Splits an answer into clauses,
  delegates per-clause verdicts to the configured `EntailmentVerifier`, and applies
  the pass/fail policy — returning the unsupported clauses so the reflect loop can
  re-enter targeting exactly what wasn't grounded. Pure logic, default lane.
  """
  use ExUnit.Case, async: true

  alias Foresight.Reflect.EntailmentGate

  # A deterministic fake verifier: a clause is supported iff some evidence string
  # contains ALL of the clause's lowercased alphabetic tokens (i.e. the evidence
  # "covers" the clause). Lets tests drive exact supported/unsupported outcomes.
  defmodule CoverageVerifier do
    @behaviour Foresight.Reflect.EntailmentVerifier

    @impl true
    def verify(clauses, evidence, _opts) do
      ev = Enum.map(evidence, &String.downcase/1)

      Enum.map(clauses, fn clause ->
        tokens = clause |> String.downcase() |> String.split(~r/[^a-z0-9]+/, trim: true)

        supported? =
          tokens != [] and Enum.any?(ev, fn e -> Enum.all?(tokens, &String.contains?(e, &1)) end)

        %{clause: clause, supported?: supported?, score: if(supported?, do: 1.0, else: 0.0)}
      end)
    end
  end

  defp opts(extra \\ []), do: Keyword.merge([entailment_verifier: CoverageVerifier], extra)

  test "splits an answer into sentence clauses" do
    result = EntailmentGate.check("Alice joined. Bob left! Did Carol stay?", ["x"], opts())
    assert result.clauses == ["Alice joined", "Bob left", "Did Carol stay"]
  end

  test "passes when every clause is covered by the evidence" do
    evidence = ["Alice joined the team in March", "Bob left the company"]
    result = EntailmentGate.check("Alice joined. Bob left.", evidence, opts())
    assert result.passed?
    assert result.unsupported_clauses == []
  end

  test "fails and reports the unsupported clauses" do
    evidence = ["Alice joined the team in March"]
    result = EntailmentGate.check("Alice joined. Bob departed to Berlin.", evidence, opts())
    refute result.passed?
    assert result.unsupported_clauses == ["Bob departed to Berlin"]
  end

  test "a blank answer trivially passes (nothing to verify)" do
    result = EntailmentGate.check("   ", ["evidence"], opts())
    assert result.passed?
    assert result.clauses == []
    assert result.verdicts == []
  end

  test "with no evidence, non-empty clauses are unsupported (ungrounded)" do
    result = EntailmentGate.check("Alice joined.", [], opts())
    refute result.passed?
    assert result.unsupported_clauses == ["Alice joined"]
  end

  test "min-supported fraction policy tolerates a partial miss" do
    evidence = ["Alice joined the team", "Bob left"]
    # 2 of 3 clauses covered = 0.66; passes at 0.6, fails at 1.0 (default).
    answer = "Alice joined. Bob left. Carol relocated to Berlin."
    assert EntailmentGate.check(answer, evidence, opts(entailment_min_supported: 0.6)).passed?
    refute EntailmentGate.check(answer, evidence, opts()).passed?
  end

  test "defaults to the Noop verifier (off) when none configured — always passes" do
    # No :entailment_verifier configured and Noop is the default → gate is inert.
    result = EntailmentGate.check("Totally unsupported claim.", [], [])
    assert result.passed?
    assert result.unsupported_clauses == []
  end
end
