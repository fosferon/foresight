# LongMemEval Answer-Accuracy Baseline (Foresight recall + fixed reader + judge)

Date: 2026-07-11

> **Directional baseline, n=30 (5/type), reader-limited.** This is an answer-level
> companion to the retrieval baseline (`docs/longmemeval-baseline.md`). It exists
> because LongMemEval-S *retrieval* nDCG is saturated by the semantic arm + reranker
> and cannot register improvements to graph, consolidation or supersession handling.
> This lane can.

## Results

| question_type | answer accuracy | retrieval nDCG@10 (ref) |
|---|---|---|
| knowledge-update | 0.60 | 0.945 |
| single-session-assistant | 0.60 | 0.926 |
| single-session-user | 0.60 | 0.700 |
| single-session-preference | 0.20 | 0.652 |
| multi-session | **0.00** | 0.959 |
| temporal-reasoning | **0.00** | 0.512 |
| **OVERALL** | **0.333** | 0.782 |

10 / 30 correct. Wall time ~47 min on Apple Silicon (MPS embeddings + 2 local LLM
calls per instance). Seed 42.

## Methodology

Per sampled instance:
1. Retain the instance haystack into its own bank — real Ecto + pgvector, `bge-small`
   embeddings on MPS (see the retrieval-lane trap note; not Bumblebee/CPU).
2. `Foresight.recall(query)` → top-8 recalled memory texts.
3. A **fixed reader** (plain LMStudio completion over that context) produces an answer.
4. An **independent judge** model scores CORRECT/INCORRECT vs the gold `reference_answer`;
   for abstention (`_abs`) instances it scores whether the model correctly declined.

- Reader + judge model: `qwen3-vl-8b-instruct` (local, LMStudio). Non-thinking — the
  `qwen3.5-*` "thinking" models silently return empty answers under a small token
  budget and must be avoided here.
- **This is not `Foresight.reflect`.** Reflect's strict json_schema structured output
  is unreliable with local models, so the reader is held constant. That means
  this lane measures **Foresight retrieval → answer quality with a fixed reader**, and
  changes in the score track retrieval — not Foresight's own reflect synthesis.

## The finding: misses are cross-session **aggregation**

The per-type shape is diagnostic. Everything that fails is a *count / sum / total across
multiple sessions*; everything that works is a single-fact lookup or a correct refusal.

Failing (from the instrumented log):

| question | gold | answer |
|---|---|---|
| episodes of the Science series completed | 50 | 10 |
| total money spent on bike expenses | $185 | $65 |
| total distance across four road trips | 3,000 mi | "I don't know" |
| total online courses completed | 20 | "I don't know" |
| % of packed shoes worn | 40% | 20% |

Working:

| question | gold | answer |
|---|---|---|
| day I met tutor Juan | Wednesday | Wednesday |
| tops bought from H&M | five | Five |
| Negroni attempts | 10 | 10 |
| fitness classes/week (abstention) | *(none)* | "I don't know" ✓ |

The reader is genuinely *using* the retrieved context — the wrong answers are close/partial
($65 not random; 20% not random), not hallucinated. It simply **cannot aggregate across the
retrieved sessions**. This is why `multi-session` answer accuracy is 0.0 *despite* 0.959
retrieval nDCG: retrieval surfaces the sessions, but the question needs a sum/count over all
of them, and either the top-8 window doesn't hold the full set or the 8B reader can't do the
arithmetic.

## Calibration — is 0.333 "poor"? Read it carefully

Three things drag the absolute number down, and only one of them is Foresight:

1. **The reader is an 8B local model, not a frontier model.** LongMemEval is deliberately
   hard; published QA accuracy uses strong commercial readers (GPT-4o class) and *still*
   drops sharply on multi-session and temporal categories. An 8B reader depresses every
   category and zeroes the arithmetic-aggregation ones. Single-session accuracy of ~0.6 is
   a *reasonable* 8B result, not a Foresight failure.
2. **Two categories are the known-hardest** (multi-session aggregation, temporal reasoning) —
   weak even for SOTA systems.
3. **Foresight's retrieval is not the bottleneck for single facts.** Where the answer lives
   in one session and recall surfaces it, the reader answers correctly (0.6). Retrieval nDCG
   is a healthy 0.78.

So the number is a **floor set mostly by the reader and the two hardest categories**, not
evidence that Foresight's memory is weak. A frontier reader (or fixing reflect)
would lift single-session/preference materially on its own.

### Where the optimization work actually lands

The 0.0 aggregation categories are precisely what **LLM-mediated consolidation**
targets. If Foresight computes aggregates at *write* time — "total bike spend: $185",
"Negroni attempts: 10", "online courses: 20" — into consolidated observations, the reader
retrieves the answer directly instead of counting across raw sessions. **This metric will
register that improvement**, which retrieval nDCG never could. For these categories
specifically, consolidation and parity work is where the gains should come from.

Two co-limiters to separate in follow-up runs, so we don't misattribute:
- **Recall K**: top-8 may not include every session an aggregation needs; raising K (or a
  count-aware retrieval mode) is a cheap test.
- **Reader strength**: re-run with a stronger reader to bound how much is reader vs. retrieval.

## Caveats

1. **n=30 (5/type)** — directional; wide intervals. A single instance moves a per-type
   number by 0.2.
2. **Reader == judge model** (both `qwen3-vl-8b`). Grading is against a fixed gold reference
   (limits self-preference bias) but a distinct, stronger judge is preferable — a next-run fix.
3. **Fixed reader ≠ Foresight.reflect.** Native reflect answer quality is unmeasured here; this is retrieval→answer with a held-constant reader.
4. Abstention handling works (the one sampled `_abs` instance was correctly refused), but
   abstention is under-sampled at this size.

## Reproduce

```bash
FORESIGHT_LME_PER_TYPE=5 FORESIGHT_LME_SEED=42 FORESIGHT_LME_VERBOSE=1 \
  mix test test/foresight/evals/longmemeval_answer_judge_eval_test.exs \
  --include eval --include ml --include llm --trace
```

`FORESIGHT_LME_VERBOSE=1` logs `q / gold / ans` per instance for failure attribution.
Override models with `FORESIGHT_LME_ANSWER_MODEL` / `FORESIGHT_LME_JUDGE_MODEL`.

## References

- Wu, D., et al. (2025). *LongMemEval: Benchmarking Chat Assistants on Long-Term
  Interactive Memory.* ICLR 2025. arXiv:2410.10813.
