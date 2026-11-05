defmodule Foresight.Reflect.EntailmentVerifiers.BumblebeeTest do
  @moduledoc """
  NLI entailment verifier decision logic. The Nx.Serving call is isolated
  behind an injectable `:nli_scorer` so the aggregation/threshold logic is unit-tested in
  the default lane; the real Bumblebee model runs only under the :ml lane. A clause is
  supported iff its MAX entailment probability over the cited evidence clears the
  threshold. Degrades to all-supported if the scorer is unavailable/crashes.
  """
  use ExUnit.Case, async: true

  alias Foresight.Reflect.EntailmentVerifiers.Bumblebee, as: NLI

  # Fake NLI: entailment prob 0.92 when the hypothesis is a substring of the premise,
  # else 0.10. Receives the flat list of {premise, hypothesis} pairs, returns probs in
  # the same order (the serving contract).
  defp scorer do
    fn pairs ->
      Enum.map(pairs, fn {premise, hypothesis} ->
        if String.contains?(String.downcase(premise), String.downcase(hypothesis)),
          do: 0.92,
          else: 0.10
      end)
    end
  end

  @clauses ["Alice joined", "Bob left"]
  @evidence ["alice joined the team in march", "carol stayed on"]

  test "a clause whose max entailment over evidence clears the threshold is supported" do
    verdicts = NLI.verify(@clauses, @evidence, nli_scorer: scorer())
    assert Enum.map(verdicts, & &1.clause) == @clauses
    assert Enum.map(verdicts, & &1.supported?) == [true, false]
    assert hd(verdicts).score == 0.92
  end

  test "threshold is configurable" do
    verdicts =
      NLI.verify(@clauses, @evidence, nli_scorer: scorer(), entailment_nli_threshold: 0.95)

    # 0.92 no longer clears 0.95 → Alice now unsupported too.
    assert Enum.map(verdicts, & &1.supported?) == [false, false]
  end

  test "a clause with no evidence is unsupported (nothing to entail it)" do
    verdicts = NLI.verify(["Alice joined"], [], nli_scorer: scorer())
    assert Enum.map(verdicts, & &1.supported?) == [false]
    assert hd(verdicts).score == 0.0
  end

  test "degrades to all-supported when the scorer crashes" do
    boom = fn _pairs -> raise "serving down" end
    verdicts = NLI.verify(@clauses, @evidence, nli_scorer: boom)
    assert Enum.all?(verdicts, & &1.supported?)
    assert Enum.map(verdicts, & &1.clause) == @clauses
  end

  test "degrades to all-supported when no scorer can be resolved" do
    # No :nli_scorer and no serving configured → cannot verify → do not block.
    verdicts = NLI.verify(@clauses, @evidence, [])
    assert Enum.all?(verdicts, & &1.supported?)
  end

  test "empty clauses → empty verdicts (no scoring)" do
    assert NLI.verify([], @evidence, nli_scorer: scorer()) == []
  end
end
