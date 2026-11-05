defmodule Foresight.Reflect.EntailmentVerifiers.Noop do
  @moduledoc """
  Default entailment verifier: verification OFF. Every clause is reported supported, so
  the grounding gate is inert until a real verifier is configured — no new cost, latency, or
  change to the honest baseline unless explicitly opted in.
  """

  @behaviour Foresight.Reflect.EntailmentVerifier

  @impl true
  def verify(clauses, _evidence, _opts) do
    Enum.map(clauses, &%{clause: &1, supported?: true, score: 1.0})
  end
end
