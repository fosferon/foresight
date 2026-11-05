defmodule Foresight.Reflect.EntailmentGate do
  @moduledoc """
  Backend-agnostic grounding (entailment) gate for reflect answers. Splits a reflect answer into
  clauses, asks the configured `EntailmentVerifier` whether the cited-memory text
  entails each, and applies the pass/fail policy — returning the unsupported clauses so
  the agentic loop can re-enter targeting exactly what wasn't grounded.

  This module owns the clause split and the policy; the verifier owns only the
  per-clause judgement. Opts:

    * `:entailment_verifier` — verifier module (default `EntailmentVerifiers.Noop`, i.e.
      off). All other opts pass through to the verifier (`:llm`, `:provider`, …).
    * `:entailment_min_supported` — fraction of clauses that must be supported to pass
      (default `1.0` — every clause must be grounded).

  Safe by construction: a blank answer passes (nothing to verify), and a verifier that
  returns a malformed result is treated as all-supported so a broken gate never blocks
  an answer.
  """

  alias Foresight.Reflect.EntailmentVerifiers.Noop

  @type result :: %{
          passed?: boolean(),
          clauses: [String.t()],
          verdicts: [Foresight.Reflect.EntailmentVerifier.verdict()],
          unsupported_clauses: [String.t()]
        }

  @doc "Check that `answer`'s clauses are entailed by `evidence` (cited-memory text)."
  @spec check(String.t(), [String.t()], keyword()) :: result()
  def check(answer, evidence, opts \\ []) when is_list(evidence) and is_list(opts) do
    clauses = split_clauses(answer)

    if clauses == [] do
      %{passed?: true, clauses: [], verdicts: [], unsupported_clauses: []}
    else
      verifier = Keyword.get(opts, :entailment_verifier, Noop)
      verdicts = safe_verify(verifier, clauses, evidence, opts)
      min_supported = clamp_fraction(Keyword.get(opts, :entailment_min_supported, 1.0))

      supported = Enum.count(verdicts, & &1.supported?)
      fraction = supported / length(verdicts)

      %{
        passed?: fraction >= min_supported - 1.0e-9,
        clauses: clauses,
        verdicts: verdicts,
        unsupported_clauses: verdicts |> Enum.reject(& &1.supported?) |> Enum.map(& &1.clause)
      }
    end
  end

  # One verdict per clause, in order. A verifier that returns the wrong shape/length (or
  # crashes) degrades to all-supported — the gate must never block an answer on its own
  # malfunction, faithful to the pipeline's safe-degradation contract.
  defp safe_verify(verifier, clauses, evidence, opts) do
    case verifier.verify(clauses, evidence, opts) do
      verdicts when is_list(verdicts) and length(verdicts) == length(clauses) ->
        Enum.map(verdicts, &normalize_verdict/1)

      _mismatch ->
        Enum.map(clauses, &%{clause: &1, supported?: true, score: 1.0})
    end
  rescue
    _ -> Enum.map(clauses, &%{clause: &1, supported?: true, score: 1.0})
  end

  defp normalize_verdict(%{clause: clause, supported?: supported?} = v),
    do: %{clause: clause, supported?: supported? == true, score: score_of(v)}

  defp normalize_verdict(_other), do: %{clause: "", supported?: true, score: 1.0}

  defp score_of(%{score: s}) when is_number(s), do: s * 1.0
  defp score_of(_), do: 0.0

  # Sentence-ish clause split: break on sentence terminators (keeping the terminator with
  # its clause via lookbehind) and hard newlines, then strip trailing terminators and
  # blanks. Deterministic; the unit is what the verifier scores.
  defp split_clauses(answer) do
    answer
    |> to_string()
    |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
    |> Enum.map(&clean_clause/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp clean_clause(piece) do
    piece
    |> String.trim()
    |> String.replace(~r/[.!?]+$/, "")
    |> String.trim()
  end

  defp clamp_fraction(f) when is_number(f), do: f |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
  defp clamp_fraction(_), do: 1.0
end
