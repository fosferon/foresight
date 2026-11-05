# foresight_bench — matched-reader Foresight-vs-Hindsight scoreboard

This note records a **fair**, matched-reader head-to-head between Foresight and
Hindsight on the LongMemEval-oracle reflect lane. Same 30 instances,
same judge, same reader model — the **only** variable is the memory architecture.

Without it, any claim that Foresight matches or exceeds Hindsight is an assertion, not a
measurement. The existing `longmemeval_reflect_judge_eval_test` only compares Foresight-reflect vs
Foresight-fixed (both arms Foresight). This adds the third arm.

## Result — parity confirmed at a higher level, no significant lead (2026-08-14)

The full head-to-head, run to completion. Same
config as the July baselines so the numbers sit alongside them: **gpt-4o-mini both
arms, gpt-4o judge, seed 42, per_type 5 (n=30), `RETAIN_EXTRACTION=concise`,
Hindsight authority on OpenRouter gpt-4o-mini (LLM + reflect + consolidation matched),
3 replicates**. Foresight side includes the current fusion default
(`:normalized`/`:zscore`).

| Arm | mean | SD | range |
|-----|------|-----|-------|
| Foresight reflect | **0.800** | 0.033 | [0.767, 0.833] |
| Hindsight reflect | 0.711 | 0.038 | [0.667, 0.733] |
| Δ (Foresight − Hindsight) | **+0.089** | 0.069 | [+0.034, +0.166] |

Paired **McNemar** exact p per replicate: **0.227 / 1.000 / 0.774 — non-significant in
all three**. 30/30 covered every run. Zero extraction fallbacks and zero skipped
consolidation merges across all three (enforced, not observed — see below).

**Verdict: statistical parity, point estimate favourable, no significant lead.** The mean delta
+0.089 sits *inside* the ±0.1 n=30 nondeterminism band, and the paired test cannot
distinguish the arms in any replicate. Anyone quoting this as a win is quoting replicate
1 (+0.167) and ignoring replicate 2 (+0.033) — the delta moved **0.132 across identical
config**, which is the whole reason the ≥3-replicate rule exists.

**What did move: Foresight's own level.** 0.708 (after the July consolidation port) → **0.800**, while
Hindsight went 0.686 → 0.711, inside its own noise. So the library got meaningfully
better and the *scoreboard* still reads parity, because the gap remains inside the band.
`multi-session`, the historically weak class, averaged 0.733 across the three (0.80 /
0.60 / 0.80) against a July figure of 0.53.

**Cost, measured not estimated:** $2.53 for three replicates ($0.84 each), read from
OpenRouter `total_usage` before and after. The ~$7-8/run figure previously circulating
was about 10x too high.

**Why the earlier attempts on the DGX were abandoned:** the GB10 runs a 32B reader at
~1.4 LLM calls/min at 69% GPU utilisation — 15-22h for one n=30 replicate — *and* a
qwen run is not comparable to these numbers anyway, since the July baselines are
gpt-4o-mini. Two DGX attempts also produced silently degraded arms (10 extraction
fallbacks, 5 skipped merges) which the harness scored without complaint; that hole is
now closed by `Foresight.Evals.DegradationWatch`, which fails the run rather than
reporting a number built on raw-blob retain.

## Result — the consolidation parity port is faithful but eval-neutral (2026-07-17)

This change ported Hindsight's decomposed consolidation merge engine (sub-batching to 8/call, drain
loop, source_memories/mentioned_at merge signals, bisection + `consolidation_failed_at` quarantine,
`consolidation_max_attempts` retry). Same fair config as the retain parity run, **only Foresight's
consolidation code changed** on top of the merged retain fixes; 3 replicates. A pre-merge code review
by two independent reviewers passed with minor comments, which were addressed.

| Arm | Retain parity only | Retain + consolidation parity |
|-----|-------------------------|----------------------------------|
| Foresight reflect | 0.711 (sd 0.016) | **0.708 (sd 0.011)** |
| Hindsight reflect | 0.667 | 0.686 |
| Δ (Foresight − Hindsight) | +0.044 | **+0.022** |
| multi-session | 0.40 (flat) | 0.53 (0.8/0.4/0.4 — noise) |
| **observations written** | 594 | **901 (+52%)** |
| McNemar exact p per rep | 1.0/0.77/1.0 | 0.55/0.75/1.0 (all n.s.) |

**Verdict: the consolidation port is faithful and causes no regression, but the eval cannot detect it.**
Foresight reflect is statistically identical with and without it (0.711 → 0.708); both remain at statistical parity
with Hindsight (McNemar n.s. throughout). The port is demonstrably doing real, correct work — the drain
loop recovered **+52% more observations** (594 → 901) that the previous code was silently leaving
unconsolidated (a genuine correctness bug, now fixed) — but those observations are **eval-invisible**:
the answers are equally good with the retain fixes alone. The multi-session "gain" (0.40 → 0.53) is entirely rep-1 noise (0.8 vs
0.4/0.4 at n=5).

**The real finding: LongMemEval's answer-judge lane has hit its sensitivity ceiling for consolidation.**
The retain parity fixes captured the *entire measurable gain* (−0.267 → parity). Consolidation and,
by extension, recall and reflect quality improvements are likely correct-but-invisible on this n=30
corpus. The conclusion drawn was to build a harder, more sensitive eval (larger n, explicit
cross-session aggregation questions, or a held-out corpus where the gaps bite) before porting further
parity work, so recall and reflect gains are measurable and honestly creditable. The consolidation
port was merged as a parity and correctness fix, credited with no eval lift.

## Result — retain parity closes the deficit (2026-07-17)

The FAIR run below measured a **significant −0.267 deficit** with both arms atomizing. A
source-level comparison of Foresight (Elixir) against `hindsight-api-slim` (Python) found the root cause was
**retain extraction**, not reflect: Foresight sent whole sessions to the extractor in ONE capped LLM
call (no chunking) and dropped the `When:` date clause from every stored fact (it had ported
Hindsight's DEAD Pydantic `build_fact_text` instead of the live inline assembler). The fix covered the
retain subsystem (chunking to ~3000-char pieces, `When:` clause restored, per-fact temporal offsets,
occurred/relative-date fallbacks, extraction temperature pinned to 0.1, max tokens) on a
retain-parity branch. Re-ran the identical fair config — **only Foresight's retain code changed**;
the Hindsight authority was byte-identical (OpenRouter gpt-4o-mini, all families matched), 3 replicates:

| Arm | mean | SD | range | prior fair baseline |
|-----|------|-----|-------|---------------------|
| Foresight reflect | **0.711** | 0.016 | [0.700, 0.733] | 0.467 |
| Hindsight reflect | 0.667 | 0.000 | [0.667, 0.667] | 0.733 |
| Δ (Foresight − Hindsight) | **+0.044** | 0.016 | [+0.033, +0.066] | −0.267 |
| multi-session | **0.40** | 0.000 | [0.40, 0.40] | 0.20 |

Paired **McNemar** exact p per replicate: **1.00 / 0.77 / 1.00 — non-significant every run** (discordant
F-only/H-only 5/4, 7/5, 6/5); 30/30 covered. **Mechanism confirmed:** observations written jumped
**162 → ~594** (591/657/535) — chunking restored the facts that were being dropped, giving consolidation
material to merge and reflect dates to reason over.

**Verdict: statistical parity, from a significant deficit.** The retain extraction fixes alone took
Foresight from **significantly behind** (−0.267, McNemar p<0.05 in 2/3) to **at parity** (+0.044, McNemar
n.s. all 3), point estimate slightly in Foresight's favor. This is **not** a lead — +0.044 is inside
the ±0.1 n=30 noise band and the paired test cannot distinguish the arms. Honest caveat: the Hindsight
arm scored 0.667 here vs 0.733 in the prior fair run (a 2-question dip, likely its own LLM
nondeterminism); even against Hindsight's better 0.733, Foresight's 0.711 is −0.022 — still parity, not
the prior chasm. Attribution is clean: the +0.311 swing is entirely the retain fixes. Consolidation, the recall
candidate pool and the reflect loop remain the places to look for a *significant* lead beyond parity.

## Result — FAIR architecture-matched run falsifies the parity story (2026-07-17)

The `## statistical parity` result below ran **Foresight on whole-session blobs vs Hindsight
on native atomic facts**. That was suspected to *handicap* Foresight, so we re-ran the head-to-head
with **both arms atomizing** (`FORESIGHT_LME_RETAIN_EXTRACTION=concise`) — the only variable
changed vs the blob run is Foresight's retain mode. Same 30 instances, gpt-4o-mini both arms,
gpt-4o judge, seed 42, per_type 5 (**n=30**), Hindsight authority on OpenRouter gpt-4o-mini, **3
replicates**.

| Arm | mean | SD | range |
|-----|------|-----|-------|
| Foresight reflect | **0.467** | 0.072 | [0.400, 0.567] |
| Hindsight reflect | 0.733 | 0.027 | [0.700, 0.767] |
| Δ (Foresight − Hindsight) | **−0.267** | 0.082 | [−0.367, −0.166] |

Paired **McNemar** exact p per replicate: **0.27 / 0.0074 / 0.021 — significant in 2 of 3**;
discordant pairs lopsided toward Hindsight every run (H-only/F-only **9/4, 13/2, 9/1**); 30/30
covered. `multi-session` stayed **0.20 / 0.20 / 0.40** (mean 0.267) — no better than the blob run.

**Verdict: the blob-handicap hypothesis is FALSIFIED.** Atomizing Foresight did **not** close the
gap — it *widened* it. The control confirms this: only Foresight's retain mode changed, yet
Foresight reflect fell **0.600 → 0.467** while Hindsight (the unchanged control) held ~0.73. So the
whole-session-blob config was Foresight's **better** config, not a handicap, and the earlier
**−0.077 "parity" was Foresight's best case, not an artifact to be corrected upward.** In the
architecture-matched config that isolates the reflect/consolidation *engine* on identical atomic
facts, Foresight is **significantly behind** Hindsight (−0.267, McNemar p<0.05 in 2/3).

**Open root-cause question at the time:** why does feeding Foresight atomic facts *lower* its reflect
accuracy when it *raises* Hindsight's? Leading hypothesis: Foresight's `concise` extraction
(gpt-4o-mini) is lossier than Hindsight's native retain, and/or blob retain incidentally gave
Foresight's reflect fuller per-hit context. This is a systematic-debugging item, not a tuning knob.

## Result — statistical parity, BLOB config (2026-07-17) — Foresight's *best* case, not fair-matched

Matched-reader run, **gpt-4o-mini on both arms**, **gpt-4o judge**, seed 42, per_type 5
(**n=30**), Hindsight authority on OpenRouter gpt-4o-mini (reflect + consolidation
matched), **3 replicates**:

| Arm | mean | SD | range |
|-----|------|-----|-------|
| Foresight reflect | **0.600** | 0.058 | [0.567, 0.667] |
| Hindsight reflect | 0.678 | 0.051 | [0.633, 0.733] |
| Δ (Hindsight − Foresight) | **0.077** | 0.020 | [0.066, 0.100] |

Paired **McNemar** p per replicate: **0.80 / 0.77 / 0.55 — all non-significant**;
discordant pairs balanced (H-only/F-only 9/7, 7/5, 7/4); 30/30 covered every run.

**Verdict: statistical parity.** The gap closed from a first measured **−0.233**
(McNemar p=0.039, significant; Foresight reflect 0.433) to **−0.077** (McNemar n.s.),
inside the ±0.1 n=30 nondeterminism band, and the paired test can no longer distinguish
the arms. This is parity with Hindsight, *not* a lead (the mean delta is
still slightly negative; `multi-session` remains the weak class at ~0.20).

The lift is attributable **solely to two behavioural ports** — recall
evidence-budget decoupling and forced-final-synthesis on loop exhaustion. **Forced hierarchical retrieval was inert during this run**
(the pinned `llm_core` 0.4.1 openai provider drops `tool_choice`), so the forcing code
is *not* the source of the gain and must not be credited for it. Original gamed baseline
context: see `## Verdict discipline` below.

## What was built (instrument — landed)

- `Foresight.Evals.HindsightBench` — drives a live Hindsight authority over its HTTP
  API through the identical lifecycle (retain the same sessions → consolidate → reflect).
  Pure core (payload/response) is unit-tested; live orchestration runs only in the lane.
- Third arm in `longmemeval_reflect_judge_eval_test.exs`, **gated** on
  `FORESIGHT_LME_HINDSIGHT_BASE_URL`. Off by default → the default/`:ml` lanes are
  unchanged and `hindsight_correct` is `nil` (never a faked 0).
- Fairness fix in `scripts/start-hindsight-fixture-authority.sh`: the LMStudio/DGX
  branch now exports the `HINDSIGHT_API_REFLECT_LLM_*` and
  `HINDSIGHT_API_CONSOLIDATION_LLM_*` families (defaulting to the primary LLM), so
  Hindsight reflect+consolidation run on gpt-oss:20b — not a silent Sonnet/other fallback.

## Appendix: an earlier local-GPU attempt (abandoned) — why not gpt-oss:20b

The results above used hosted models. Before them, the comparison was attempted on a
local GPU host, and this appendix records that attempt. The initial plan named `gpt-oss:20b` as the fair reader. A live run proved that
self-defeating: gpt-oss:20b (served via Ollama) is a **reasoning model** that emits a
large hidden `reasoning` block before any answer. Consequences measured directly:

- **~90s for a one-word reply**; ~15–40 LLM calls per instance × 30 instances ≈ a
  7–30h run — the reflect agentic loop timed out at 5 min on instance 1.
- **Content-starved under real token budgets** (reflect uses `max_tokens: 512`): the
  reasoning eats the budget, `content` comes back empty. Both arms suffer — Foresight
  reflect/reader AND Hindsight fact-extraction (instance 1's Hindsight bank had
  `0 nodes, 0 observations`). The reader, not the memory architecture, zeroed the scores.

Fairness only requires **both arms use the SAME reader** — not that specific model. So
the matched reader is a **fast, non-reasoning, JSON-reliable** model:
`qwen2.5-coder:32b-instruct` (2s warm, clean UNfenced JSON, no reasoning block). Judge
stays `mistral-small:latest` (reader ≠ judge).

## Appendix: reproducing the matched-reader run on a local GPU host (~1–2h)

It needs a reachable GPU host serving the matched reader, a fresh Hindsight authority
pointed at it, and a Python environment with sentence-transformers.

### 1. Start a FAIR Hindsight authority (reader+reflect+consolidation on the SAME model)

```bash
cd /path/to/hindsight/hindsight-api
M=qwen2.5-coder:32b-instruct ; U=http://gpu-host.local:11434/v1
PGPASSWORD=postgres psql "postgresql://postgres:postgres@localhost:5432/postgres" \
  -c "CREATE DATABASE foresight_bench_qwen"   # pre-create so createdb never prompts
PGPASSWORD=postgres \
HINDSIGHT_API_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/foresight_bench_qwen \
HINDSIGHT_API_TENANT_EXTENSION="hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension" \
HINDSIGHT_API_TENANT_API_KEY=sk-foresight-fixtures-dev \
HINDSIGHT_API_LLM_PROVIDER=openai HINDSIGHT_API_LLM_BASE_URL=$U HINDSIGHT_API_LLM_API_KEY=lm-studio HINDSIGHT_API_LLM_MODEL=$M \
HINDSIGHT_API_REFLECT_LLM_PROVIDER=openai HINDSIGHT_API_REFLECT_LLM_BASE_URL=$U HINDSIGHT_API_REFLECT_LLM_API_KEY=lm-studio HINDSIGHT_API_REFLECT_LLM_MODEL=$M HINDSIGHT_API_REFLECT_LLM_TIMEOUT=300 \
HINDSIGHT_API_CONSOLIDATION_LLM_PROVIDER=openai HINDSIGHT_API_CONSOLIDATION_LLM_BASE_URL=$U HINDSIGHT_API_CONSOLIDATION_LLM_API_KEY=lm-studio HINDSIGHT_API_CONSOLIDATION_LLM_MODEL=$M HINDSIGHT_API_CONSOLIDATION_LLM_TIMEOUT=300 \
  uv run hindsight-api --port 8899 --host 127.0.0.1
```

Bypass `scripts/start-hindsight-fixture-authority.sh`'s guard wrapper: its `set -m`
job-control turns gpt-oss/uv's cosmetic `Password:` banner into a runaway. The direct
`uv run` above comes up healthy in seconds.

### 2. Run the eval with the third arm ON (matched 30 instances, seed 42)

```bash
FORESIGHT_ML_PYTHON=~/.cache/foresight-ml-venv/bin/python \
FORESIGHT_LLM_BASE_URL=http://gpu-host.local:11434/v1 \
FORESIGHT_LME_ANSWER_MODEL=qwen2.5-coder:32b-instruct \
FORESIGHT_LME_JUDGE_MODEL=mistral-small:latest \
FORESIGHT_LME_PER_TYPE=5 \
FORESIGHT_LME_SEED=42 \
FORESIGHT_LME_HINDSIGHT_BASE_URL=http://127.0.0.1:8899 \
FORESIGHT_LME_HINDSIGHT_API_KEY=sk-foresight-fixtures-dev \
mix test test/foresight/evals/longmemeval_reflect_judge_eval_test.exs --include ml
```

The report prints Foresight-reflect vs Hindsight-reflect per question_type plus an
OVERALL paired **McNemar** and Wilson CIs. Full JSON at
`$TMPDIR/foresight_lme_reflect_judge_results.json` (`hindsight` block).

### 3. Verdict discipline

- **Parity = |delta| within the ±0.1 n=30 nondeterminism band.** One run is a noisy
  point (the same variance that turned Foresight's 0.80 into a stable 0.70).
- For a real verdict: **≥2 runs**, or explicitly acknowledge the band. Feed per-run
  accuracies to `Foresight.Evals.Stats.replicate_summary/1` to bound the A/A floor.
- The report states `covered N/total` — a partial Hindsight run (some instances errored)
  can never masquerade as full coverage.

Foresight baseline to compare against: reflect ~0.70 stable (the reflect regression baseline
recorded before this run).

## Why this measurement matters

Code-level parity with Hindsight is complete and reviewed. This is the matching
**performance** measurement, so the decision on whether to invest in going beyond parity
rests on evidence rather than assertion.
