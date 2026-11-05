# Reflect

`recall` retrieves. `reflect` answers.

The difference is that reflect gives a model *tools* and lets it search memory
itself, repeatedly, deciding what to look for next based on what it just found.

## What the loop actually does

The model is handed four tools:

- **`recall`** — the ordinary ranked search
- **`search_observations`** — search consolidated knowledge rather than raw facts
- **`search_mental_models`** — search curated, longer-lived structures
- **`expand`** — pull the surrounding context of something already found

A question like *"why did the payments migration slip?"* typically produces a
first search that surfaces the slip, an entity name the model had not been given,
and a second search on that name. One-shot retrieval cannot do that, because the
second query does not exist until the first result comes back.

This is worth what it costs:

| | accuracy |
| --- | --- |
| fixed reader (recall → top-8 → answer) | 0.467 |
| **reflect** | **0.833** |

McNemar exact **p = 0.001** over the same memories with the same model. The
delta is the loop, not the data.

## Observations, and why they exist

`retain` stores facts. **Consolidation** merges related facts into
*observations* — durable statements that outlive any single conversation.
Twenty scattered mentions of someone's schedule become one observation about how
they work.

`search_observations` reads that layer. It is often the difference between an
answer assembled from twenty fragments and one drawn from a single settled
statement.

Consolidation runs on write, in sub-batches, with a drain loop. Fixing that loop
recovered **+52% more observations** (594 → 901) that were previously left
unconsolidated. Notably, it did *not* move end-to-end accuracy — 0.711 → 0.708,
which is nothing. It shipped as a correctness fix with no benefit claimed, and
that is exactly how it is recorded.

## Mental models

A mental model is a curated synthesis a human or a refresh job wrote for a topic.
Reflect treats them as the most trustworthy tier: the agent's `search_mental_models`
tool ranks a bank's models by embedding similarity to its query, returns at most
`max_results`, and the most relevant few are already in the opening context before
the first tool call.

Every model comes back with a staleness verdict. A model is stale when a memory in
its scope was written after its last refresh. The scope is the model's tags under
`trigger.tags_match` (`any`, `all`, `any_strict`, `all_strict`, the recall
semantics) and `trigger.fact_types` when set; an untagged model is global, so any
new memory makes it stale, and a model that was never refreshed is stale by
definition. `staleness_reason` says which case applies. The same verdict is on
`get_mental_model` and `list_mental_models`, computed when asked rather than read
from a flag written at refresh time.

Embeddings for models live in their own table and are kept current lazily: a model
whose content, or whose bank's embedding model or dimension, no longer matches its
stored embedding is re-embedded before the next search. Curated models that predate
this table are indexed on first use.

## Checking that it actually ran

A model that cannot call tools cannot run the loop, and Foresight falls back to a
fixed structured pipeline rather than failing. Silently getting the fallback
while believing you have the agentic loop is the most likely way to be
disappointed by reflect.

The trace tells you which happened:

```elixir
{:ok, %{"trace" => %{"mode" => mode}}} = Foresight.reflect(ctx, %{"query" => q, "trace" => true})
mode  #=> "agentic" or "fixed"
```

If you see `"fixed"` unexpectedly, the LLM you configured does not do native tool
calling. Reasoning-style models are a common cause of a subtler version: they
spend the token budget on reasoning and return empty `content`, which zeroes the
answer without erroring. A direct instruct model is the safer choice for this
role.

## Grounding

Reflect records which memories an answer rests on, and can be required to meet
thresholds before answering — minimum grounding count, minimum diversity of
sources, minimum provenance clusters. Configure under `engine:`:

```elixir
config :foresight,
  engine: [
    reflect_max_iterations: 10,
    reflect_min_grounding_count: 1,
    reflect_min_diverse_grounding_count: 1,
    reflect_max_context_tokens: 100_000,
    reflect_timeout_ms: 120_000
  ]
```

Raising the grounding minimums makes the system decline to answer more often. For
an assistant that is usually the wrong trade; for anything that must not
confabulate, it is the point.

## A limitation worth stating

Hindsight opens its loop with a forced sequence of tool calls. Foresight cannot
currently express that: `tool_choice` is absent from `llm_core` entirely, so
forced-tool retrieval is not available. Foresight seeds the opening context
instead, which is a different mechanism reaching a similar place, and the
measured parity above was obtained with that difference in place.
