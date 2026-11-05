defmodule Foresight.Reflect.EntailmentVerifier do
  @moduledoc """
  Seam for the reflect grounding/entailment gate: given the clauses of a reflect answer and
  the text of its cited memories (evidence), return a per-clause verdict on whether the
  evidence entails the clause.

  Pluggable so the substrate is a deployment/hardware choice, not a hardcode — selected
  via the engine `:entailment_verifier` config, the same pattern as `:embedder` /
  `:reranker` / `:entity_extractor`. Implementations:

    * `EntailmentVerifiers.Noop` — the DEFAULT: verification off, every clause passes.
      Zero cost/latency unless opted in (mirrors `entity_semantic_recall` defaulting
      false), so the gate never changes behaviour or the honest baseline until enabled.
    * `EntailmentVerifiers.LLMJudge` — one structured LLM call over the existing routing.
    * `EntailmentVerifiers.Bumblebee` — a dedicated NLI cross-encoder (calibrated
      entail/neutral/contradict); the independent signal, for hosts with the headroom.

  A verdict's `score` is the implementation's confidence in [0.0, 1.0] (the entailment
  probability for NLI; 1.0/0.0 for boolean judges). The gate — not the verifier — owns
  the clause split and the pass/fail policy.
  """

  @type verdict :: %{clause: String.t(), supported?: boolean(), score: float()}

  @doc """
  Return one verdict per clause. `evidence` is the cited memories' text. Implementations
  MUST return exactly one verdict per input clause, in order, and MUST degrade safely
  (an unavailable model/LLM is not an exception — return `supported?: true` so a broken
  verifier never blocks an answer, faithful to the pipeline's LlmCore isolation).
  """
  @callback verify(clauses :: [String.t()], evidence :: [String.t()], opts :: keyword()) ::
              [verdict()]
end
