# Evaluation

This library makes measured claims, so it owes you the method. This guide is
mostly about how to disbelieve the numbers efficiently.

## The headline, with its uncertainty

Matched-reader benchmark on LongMemEval-oracle. Both arms use the same reader
model, the same judge, and the same 30 instances; the only variable is the memory
architecture. Three replicates:

| arm | mean | SD | range |
| --- | --- | --- | --- |
| Foresight reflect | **0.800** | 0.033 | [0.767, 0.833] |
| Hindsight reflect | 0.711 | 0.038 | [0.667, 0.733] |
| Δ | **+0.089** | 0.069 | [+0.034, +0.166] |

McNemar exact p = 0.227 / 1.000 / 0.774 — **non-significant in all three**.

**Verdict: parity.** The mean delta sits inside the ±0.1 band that n=30
nondeterminism produces, and the paired test cannot separate the arms in any
replicate.

The most useful number in that table is the delta's **range: +0.034 to +0.166,
across identical configuration.** Replicate 1 alone reads like a clear win.
Publishing it would have been wrong. This is why the project's own rule is ≥3
replicates before any claim, and why a single run of this benchmark should never
persuade you of anything.

## Two metrics, two different questions

**Answer accuracy** — did reflect answer correctly? The number that matters, and
the one with a ceiling problem: a consolidation change that produced +52% more
observations moved it 0.711 → 0.708. The lane cannot see improvements it should
plausibly be able to see, so a null result here is weak evidence of no effect.

**nDCG@10 / MRR** — did recall put the right memories at the top? Far more
sensitive, because it grades ranking directly instead of waiting for a downstream
model to notice. This is how the fusion default was chosen (+0.1009 nDCG@10, CI
excluding zero).

They answer different questions and do not substitute for one another. The
fusion change is a demonstrated *ranking* win that did **not** yield a
significant *accuracy* lead. Both statements are true and this documentation
keeps them apart.

## Where the labels come from

**Relevance labels are agent-anchored, not human-graded.** Stated plainly because
an eval number is worth exactly what its labels are worth.

- Agent-produced labels carry `source: :agent` — a distinct provenance from
  `:human`, so nothing downstream can mistake one for the other.
- LLM-judged labels carry `source: :llm` and stamp `judge_model` as
  `"<model>@<rubric-version>"`, derived from the rubric *actually sent*. There is
  deliberately no caller override for that field: one existed, and it let a label
  claim a rubric version the judge never saw.
- Agreement is gated on Cohen's quadratic-weighted kappa ≥ 0.6.

The known risk this leaves open: a model-judged relevance label could share a
bias with the ranking change being evaluated. That threatens the *magnitude* of
the +0.1009, not its direction, and the honest remedy is a human-labelled subset
rather than a code change. If you need human-anchored ground truth for a
publication or regulatory claim, this repository does not have it, and the kappa
gate does not manufacture it.

## The harness refuses to score a broken run

`retain` degrades rather than failing when the LLM times out: extraction falls
back to storing raw content, consolidation skips a scope after exhausting
retries. Correct for production, disastrous for a benchmark — the arm silently
gets worse while everything reports healthy.

This is not hypothetical. One head-to-head ran with **10 extraction fallbacks and
5 skipped merges** — the arm was storing raw blobs instead of extracted facts,
which is precisely the deficit worth −0.267 accuracy — and the harness would have
printed a confident scoreboard had it not independently run out of wall-clock.

`Foresight.Evals.DegradationWatch` now counts both via telemetry, and the
benchmark asserts zero *after* printing its report: the numbers stay visible so a
failed run is diagnosable, but the test fails so they cannot be quoted as a
measurement.

## Reproducing

```bash
FORESIGHT_LME_ANSWER_MODEL=... \
FORESIGHT_LME_JUDGE_MODEL=... \
FORESIGHT_LME_PER_TYPE=5 \
FORESIGHT_LME_SEED=42 \
mix test test/foresight/evals/longmemeval_reflect_judge_eval_test.exs --include eval --include ml
```

Set `FORESIGHT_LME_HINDSIGHT_BASE_URL` to add the Hindsight arm. Full method,
every historical result including the unflattering ones, and the reasoning behind
each, live in [the bench write-up](https://github.com/fosferon/foresight/blob/main/docs/foresight_bench.md) in the repository.

Two practical notes, learned expensively. Reader choice dominates: a 32B model on
modest hardware took **15–22 hours** per replicate where a hosted model took
**18 minutes** and cost **$0.84**. And both arms must run the same reader — a
mismatched reader measures the models, not the memory.

## What has not been measured

Latency, throughput, memory footprint, and stability under load — absolutely or
comparatively. Every number in this project is answer quality. Since accuracy is
now at parity, those are the dimensions where the two implementations might
actually differ, and nobody has looked yet.
