# How recall works

Recall runs four searches at once and merges them into one ranked list. The
merge, it turns out, matters more than most of the searches.

## Four ways of being relevant

A memory can be worth returning for quite different reasons, and no single index
captures all of them.

**Semantic** — embedding similarity. Finds *"the deploy took ages"* when you
asked about *"slow migrations"*. Blind to exact identifiers: it has no special
respect for `v2.3`. A candidate has to clear a cosine-similarity floor to enter
this arm at all: the bank config field `recall_semantic_floor`, default `0.3`.
The right value depends on the embedding model. `BAAI/bge-small-en-v1.5` scores
unrelated text at roughly 0.33–0.36 and related text at 0.55–0.78, so on that
model the default admits nearly the whole bank and leaves the reranker to sort it
out, while about 0.45 already sheds the off-topic candidates. Measure on your own
corpus before raising it; a floor above the model's related-text band empties the
arm. The trace reports the floor in force as `semantic_similarity_floor`.

**Keyword** — Postgres full-text search over a stored `tsvector`. The opposite
temperament. It will find `v2.3` and `KB-4156` precisely, and miss every
paraphrase. Deliberately faithful to Hindsight here: tokens are OR-joined with no
`:*` prefix matching, so `run` does not silently match `running`.

**Graph** — traversal of the entity graph built during `retain`. Finds memories
that never mention your query terms but are *about* an entity that does. This is
the arm that connects "Maria" to "Lisbon" without either sentence containing both.

**Temporal** — time-proximity. Matters for "what else was happening that week?".
Worth knowing: on our benchmark corpus this arm fires on **29 of 4,785**
candidates. It is a specialist, not a workhorse, and any tuning that appears to
learn something about it is almost certainly learning noise.

Each arm returns its own ranked list with its own scores, on its own scale.

## The merge is the interesting part

Four lists have to become one. The obvious approach — the one Foresight shipped
originally and Hindsight still uses — is **Reciprocal Rank Fusion**: ignore the
scores, use only positions, sum `1/(k + rank)` across arms.

RRF is robust precisely *because* it discards the scores. It cannot be fooled by
one arm's scale.

It can, however, be blinded by it. Consider semantic returning:

```
1. 0.95  "the payments migration slipped to Q3"
2. 0.31  "payments team standup notes"
```

To RRF these are simply *first* and *second*. The chasm between 0.95 and 0.31 —
information the embedder computed and handed over — is thrown away.

Normalizing instead keeps it: rescale each arm's native scores to a common range,
then add. We measured both over 134 queries carrying graded relevance labels,
paired per query, with a 2,000-sample bootstrap:

| mode | nDCG@10 | MRR | vs `:rrf` | 95% CI |
| --- | --- | --- | --- | --- |
| `:rrf` | 0.7670 | 0.7760 | — | — |
| `:normalized` / `min_max` | 0.8273 | 0.8508 | +0.0603 | [0.0322, 0.0906] |
| **`:normalized` / `zscore`** | **0.8679** | **0.9027** | **+0.1009** | **[0.0597, 0.1476]** |

`zscore` beats `min_max` because a single outlier squashes a min-max range,
while a standard-deviation scale is unmoved by it.

**`:normalized` with `:zscore` is the default.** The number to watch is MRR
0.776 → 0.903: that is *the right memory sitting at rank 1* far more often, and
rank 1 is what reflect reads first.

### What that result does not say

It is one corpus, and the relevance labels were produced by a model rather than a
person. A ranking improvement is not an answer-quality improvement — the same
change did **not** produce a significant lead in end-to-end accuracy. See
**[Evaluation](evaluation.md)**.

## Weights, and a negative result worth reading

`:normalized` and `:hybrid` accept per-arm weights:

```elixir
config :foresight,
  recall_fusion: [
    mode: :normalized,
    normalization: :zscore,
    weights: %{"semantic" => 1.5, "keyword" => 1.0, "graph" => 0.5, "temporal" => 1.0}
  ]
```

Weights are ignored under `:rrf`, which ranks on position alone.

We tried to *learn* these weights per bank — coordinate ascent on a training
split, scored once on held-out queries. Across 12 query-level splits it was worth
**+0.0153 nDCG@10 (SD 0.0275), and negative in 3 of them**. Not significant, and
not shipped.

The honest lesson is that picking the right merge *strategy* was worth ~7× more
than tuning weights within it, and cost nothing at runtime. If you are tempted to
tune weights, measure first — and measure on held-out queries, not the ones you
tuned on.

## After the merge

The fused list is truncated to a rerank window, optionally passed to a
cross-encoder reranker, boosted, and trimmed. The default reranker is
`Passthrough` — it preserves fusion order — so out of the box your ranking *is*
the fusion result. Configure `Rerankers.Bumblebee` or
`Rerankers.SentenceTransformers` for real reranking, at the cost of the ML stack.

### The rerank window

The window is twice the resolved recall budget (Hindsight parity: budget `low`
is 100, so 200 candidates go to the cross-encoder), or the bank config field
`recall_rerank_window` when set. On a bank with a few hundred fused candidates
per query that means *all* of them are reranked, and the cross-encoder's cost is
linear in the window. `cross-encoder/ms-marco-MiniLM-L-6-v2` scores ~200 pairs in
about a second on an Apple GPU; `BAAI/bge-reranker-v2-m3` takes five to eight
times longer on the same passages. If you run a heavy reranker, set
`recall_rerank_window` to something like 40–100 and measure what it costs you in
hit@k before going wider — every response carries the numbers to do that (see
`stats` below).

### Which reranker

The default sentence-transformers model, MS MARCO MiniLM, is tuned for web
passages and flattens abstract or philosophical paraphrase: it scores a correct
paraphrase and an off-topic sentence at the same logit (around −11). On a labelled
20-query set over such a corpus, `BAAI/bge-reranker-v2-m3` moved hit@1 from
13/20 to 18/20 and MRR from 0.77 to 0.93, for the latency above. Pick the model
for the corpus, set `FORESIGHT_RERANKER_MODEL_ID` (or `:ml, :reranker_model_id`),
and re-measure any `min_score` cutoff: different models put their logits on
different scales.

### The reranker never holds a database connection

Under Mode C tenancy a scope is a checked-out connection with `SET ROLE`, and the
pool's checkout timeout (15 s by default) counts everything run inside it. Recall
therefore runs as scoped database phases — bank config, retrieval, result
enrichment — with the query embedding and the reranker between them, on no
connection at all. A reranker that takes ten seconds makes a slow recall, not a
dropped connection and a failed one.

## The score, and cutting off on it

Every result carries `"score"`: the reranker's calibrated score after boosts, the
number the results are ordered by. With the sentence-transformers reranker the
pre-boost value is sigmoid(cross-encoder logit): the worker always hands back raw
logits, whatever the model's own default activation. Different models put their
logits on different scales, so re-measure any cutoff when you change the model. Pass `"min_score"` (a non-negative number) to
drop everything below it; the cutoff runs after boosting and before the token
trim, so the trim never spends budget on results you would discard. Both are
Foresight extensions to the Hindsight recall contract.

```elixir
{:ok, %{"results" => results}} =
  Foresight.recall(ctx, %{"query" => "...", "min_score" => 0.5})

Enum.map(results, & &1["score"])  #=> [0.91, 0.74, 0.52]
```

## Seeing what happened

Every response carries a small `stats` map: how many fused candidates there
were, the rerank window in force, how many candidates were actually reranked,
how many results survived, and the retrieval, rerank and total milliseconds. It
is cheap, always on, and the first thing to look at when recall is slow:

```elixir
{:ok, %{"stats" => stats}} = Foresight.recall(ctx, %{"query" => "..."})
stats
#=> %{"candidates" => 187, "rerank_window" => 200, "rerank_candidates" => 187,
#     "results" => 12, "retrieval_ms" => 410, "rerank_ms" => 6_900, "total_ms" => 7_400}
```

That shape says the reranker is doing all the work over the whole fused set; a
smaller `recall_rerank_window` is the first lever.

Pass `trace: true` and recall explains itself in full: per-arm entry points and
native scores, the fused ordering, what each stage pruned, and per-stage `timings_ms`.

```elixir
{:ok, %{"trace" => trace}} = Foresight.recall(ctx, %{"query" => "...", "trace" => true})
trace["fusion"]  #=> %{"algorithm" => "normalized", "normalization" => "zscore", "k" => 60}
```

That `"algorithm"` field is derived from the configuration actually in force. It
used to be hardcoded to `"rrf"`, which meant that after the default changed it
confidently reported the wrong algorithm on every single request — the one field
an operator would consult to find out what really ran.
