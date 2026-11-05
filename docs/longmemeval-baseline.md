# LongMemEval Recall-Quality Baseline (Foresight Real-ML Pipeline)

**Date:** 2026-07-10

> **Status: directional baseline, not a final number.** Stratified sample of 30
> instances (5 per question type). A full-500 run is required before any ranking
> claim against published systems. See *Caveats*.

## Results

Real pipeline: Ecto + pgvector, `sentence_transformers` `bge-small-en-v1.5`
embeddings and `ms-marco-MiniLM-L-6-v2` reranker, **both verified on MPS GPU
(`device=mps:0`, introspected at runtime, not assumed)**.

| question_type | n | nDCG@10 | MRR | Recall@5 |
|---|---|---|---|---|
| multi-session | 5 | 0.959 | 1.000 | 0.900 |
| knowledge-update | 5 | 0.945 | 1.000 | 0.900 |
| single-session-assistant | 5 | 0.926 | 0.900 | 1.000 |
| single-session-user | 5 | 0.700 | 0.685 | 0.800 |
| single-session-preference | 5 | 0.652 | 0.612 | 0.800 |
| temporal-reasoning | 5 | 0.512 | 0.618 | 0.500 |
| **OVERALL** | **30** | **0.782** | **0.802** | **0.817** |

### Cross-check: MPS vs CPU backend (same model, same sample)

The identical stratified sample was scored twice, once per embedding backend, as a
provenance and sanity check. The two implementations of the same `bge-small` weights
agree within ~2%, which is the expected numeric drift — evidence that both runs are
real measurements rather than artifacts of one backend:

| backend | nDCG@10 | MRR | Recall@5 | wall time |
|---|---|---|---|---|
| `sentence_transformers` / MPS (**authoritative**) | 0.782 | 0.802 | 0.817 | 30.7 min |
| Bumblebee / EXLA CPU (cross-check only) | 0.767 | 0.794 | 0.817 | 76 min |

The `sentence_transformers`/MPS row is the authoritative baseline: it is the pipeline
closest to a GPU production deployment, and its device was introspected at runtime. The
CPU row is retained only as a cross-check.

## Methodology

### Pipeline

- **Storage**: `Foresight.Storage.Ecto` (PostgreSQL + pgvector, ephemeral `PostgresHarness` instance)
- **Embedder**: `Foresight.Embedders.SentenceTransformers` → `BAAI/bge-small-en-v1.5` (384 dim), device `mps:0`
- **Reranker**: `Foresight.Rerankers.SentenceTransformers` → `cross-encoder/ms-marco-MiniLM-L-6-v2`, device `mps:0`
- **Retrieval**: multi-strategy RRF (semantic + keyword + graph + temporal), then cross-encoder rerank of the top candidates

### Dataset

- **Split**: `longmemeval_s` (LongMemEval_S, Wu et al., ICLR 2025) — 500 instances, distractors baked in
- **Sample**: stratified **5 per question_type = 30 instances**, seed `42`
  (`:rand.seed(:exsss, {42, 294, 546})`, reproducible)
- **Sessions embedded**: 1,421 across the 30 instances

### Protocol

- **Per-instance banks**: each instance's haystack is retained into its own fresh,
  instance-scoped bank (`bank_id = "lme-ml-" <> question_id`); recall runs against that
  bank only; scored against that instance's `answer_session_ids`. Banks never leak across
  instances.
- **Granularity**: session-level. Each session becomes one memory (keyed by `session_id`);
  relevance labels are the gold `answer_session_ids`. This matches the paper's session-value index.
- **Synchronous retain** (`"async" => false`): embeddings are computed inline; a per-bank SQL
  check confirms `embedding_384 IS NOT NULL` before recall.
- **Deduplication**: recall results are deduped by `metadata["eval_id"]` (keeping the
  best-ranked occurrence) before scoring, since the multi-strategy pipeline can surface the
  same memory via more than one arm.
- **Scoring**: `Foresight.Evals.Runner` over `Foresight.Evals.RankingMetrics` — nDCG@10, MRR,
  Recall@5. These are **ID-based, gaming-resistant** metrics; they never inspect answer text.
  (This is deliberately *not* the quarantined `Foresight.Evals.RecallQuality` phrase-matcher.)

### Compute

- Wall time: 1,840,715 ms (~30.7 min) for 30 instances on MPS (Apple Silicon M-series)
- Includes Postgres retain + embedding + entity extraction + RRF + rerank per instance —
  embedding is only part of the cost, which is why MPS is ~2.5× faster than CPU here rather than ~10×.

## Calibration vs. Published LongMemEval Baselines

The LongMemEval paper (Wu et al., ICLR 2025) reports session-level retrieval for flat-index
dense and sparse retrievers in Appendix E.1. As reported (Recall@5 / nDCG@5 — **note @5, not
@10** — and **not independently re-verified against the appendix PDF in this run**):

| System (paper, session-level) | Recall@5 | nDCG@5 |
|---|---|---|
| BM25 | ~0.51 | ~0.54 |
| Contriever | ~0.67 | ~0.69 |
| Stella V5 1.5B | ~0.70 | ~0.73 |

> **Correction:** an earlier draft of this doc cited a fabricated calibration table
> (e.g. "Contriever nDCG@10 = 0.663 … Foresight beats all published baselines"). Those
> figures did not match the paper and the superiority claim is withdrawn. The numbers above
> are the paper's session-level @5 figures as reported by the source; treat them as
> approximate pending a primary re-check.

### Verdict (deliberately cautious)

Foresight's Recall@5 = 0.817 on this n=30 sample sits **in a competitive range** with the
paper's dense retrievers (Contriever/Stella ~0.67–0.70 Recall@5). That is encouraging, but it
is **not** a ranking claim:

1. **n=30, 5 per type** — confidence intervals are wide; a single instance moves a per-type
   number by 0.2. This is a smoke-level directional read.
2. **Protocol differs** — the paper scores all ~470 non-abstention instances; we score a
   stratified sample of 30. nDCG@10 (ours) and nDCG@5 (paper) are different columns and are
   not directly comparable.
3. **Fusion advantage is plausible but unproven at scale** — Foresight fuses four arms plus a
   cross-encoder rerank vs. the paper's single flat retriever, which *should* help, but the
   only honest way to claim it is a full-500 run against the same protocol.

The per-type shape is the credible signal: strong on multi-session / knowledge-update
(nDCG ~0.95) and weakest on temporal-reasoning (0.512). That ordering matches the paper's own
finding that temporal reasoning is the hardest retrieval class and benefits from time-aware
query expansion — a good sign the pipeline is behaving sensibly rather than gaming a metric.

### Caveats

1. **Sample size**: 30 instances (5/type) vs. 500 in the full benchmark — directional only.
2. **Abstention (`_abs`) instances**: not separately audited here; instances with empty gold
   session sets contribute degenerate ranking scores and should be excluded/handled explicitly
   in a full run.
3. **Retrieval only**: this report covers ranking quality (nDCG/MRR/Recall). Answer-generation
   quality (reflect / LLM-judge) is a separate, not-yet-run concern.

## GPU Backend Trap (read before running)

**Bumblebee/EXLA embedding is CPU-bound on Apple Silicon — XLA has no Metal backend.** It does
not error; it silently runs on CPU and grinds for ~2.5× longer. Two prior attempts at this
baseline fell into it.

For GPU in dev, use `sentence_transformers`:

- `FORESIGHT_LOCAL_ML_BACKEND=sentence_transformers`
- `python_executable` → a torch + sentence-transformers venv with MPS, e.g.
  `~/.cache/foresight-ml-venv/bin/python`
- `force_cpu: false` → the worker's `_detect_device` returns `None`, letting
  sentence-transformers auto-select `mps`.

The eval lane **introspects and asserts the device** (`PythonLocalWorker.device_info/1` →
must start with `mps`, else it hard-fails) so a silent CPU fallback can never again be mislabeled
as a GPU run. On deploy, the GPU depends on the target host (e.g. DGX Spark = CUDA).

## Reproducibility

```bash
# Fetch the dataset (once)
mix foresight.evals.fetch longmemeval_s

# Run the authoritative MPS lane (requires PostgreSQL + the sentence-transformers venv)
FORESIGHT_LME_PER_TYPE=5 FORESIGHT_LME_SEED=42 \
  mix test test/foresight/evals/longmemeval_real_ml_eval_test.exs --include eval --include ml --trace

# Scale up (10/type). It refuses to run unless the embedder is actually on mps.
FORESIGHT_LME_PER_TYPE=10 \
  mix test test/foresight/evals/longmemeval_real_ml_eval_test.exs --include eval --include ml --trace
```

Machine-readable results are written to `$TMPDIR/foresight_lme_real_ml_results.json`
(includes the introspected `embedder_device` / `reranker_device`).

## References

- Wu, D., Wang, H., Yu, W., Zhang, Y., Chang, K.-W., & Yu, D. (2025). *LongMemEval:
  Benchmarking Chat Assistants on Long-Term Interactive Memory.* ICLR 2025. arXiv:2410.10813.
