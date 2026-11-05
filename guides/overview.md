# Foresight

Foresight gives a program a memory it can be asked about.

Not a vector store you query, and not a log you grep. You hand it things that
happened — conversations, documents, events — and later you ask it questions in
plain language. It works out what is relevant, reasons over it, and answers with
its sources attached.

```elixir
Foresight.retain(ctx, %{"items" => [%{"content" => "Maria moved to the Lisbon office in March."}]})
Foresight.retain(ctx, %{"items" => [%{"content" => "Maria is leading the payments migration."}]})

Foresight.reflect(ctx, "who should I ask about payments in Portugal?")
#=> Maria — she leads the payments migration and works from Lisbon.
```

Nobody wrote a rule connecting *Portugal* to *Lisbon*, or *payments migration* to
*payments*. Two facts arrived weeks apart and were never stored together. The
answer comes from putting them side by side at question time.

## Three verbs

Everything is built from three operations, and the distinction between the last
two is the one worth internalising.

**`retain`** — give it something that happened. It extracts discrete facts,
embeds them, pulls out entities and links them into a graph. This is a write, and
it does real work: a session of conversation becomes many small, dated,
individually retrievable facts.

**`recall`** — ask for relevant memories. You get ranked results and their
scores. It does not interpret; it retrieves. Use it when your own code will
decide what the results mean.

**`reflect`** — ask a question and get an answer. Under the hood a model searches
memory itself, in a loop, deciding what to look for next based on what it has
found so far. Use it when the answer requires combining things.

The gap between `recall` and `reflect` is not cosmetic. In our benchmark, reflect
scores **0.833** against a fixed reader's **0.467** over the same memories —
McNemar p = 0.001. Same data, same model, different way of using it.

## What it is honestly good at

Foresight is a port of Python's [Hindsight](https://github.com/vectorize-io/hindsight),
and it is measured against it rather than described in relation to it. Three
replicates, matched reader and judge, n=30:

| | reflect accuracy |
| --- | --- |
| Hindsight (reference) | 0.711 (SD 0.038) |
| Foresight | **0.800** (SD 0.033) |

Δ +0.089, McNemar p = 0.227 / 1.000 / 0.774 — **not significant in any replicate**,
and the mean delta sits inside the ±0.1 noise band for n=30.

So: **parity.** The point estimate favours Foresight; the statistics do not
support calling it a lead, and this documentation will not call it one. If that
reads as underselling, consider that the delta ranged +0.034 to +0.166 across
*identical configuration* — a single run of this benchmark can be made to say
almost anything, and we have three.

What you get from the Elixir port is not better answers. It is the BEAM: real
concurrency, supervised processes, and — if you take it as a library rather than
a service — no network hop between your application and its memory.

## What it is not

- **Not a general vector database.** It has opinions about what memory *is*:
  dated facts, entities, relationships, consolidated observations. If you want
  raw nearest-neighbour lookup over arbitrary embeddings, use pgvector directly.
- **Not free of LLM calls.** `retain` uses a model to extract facts; `reflect`
  uses one to reason. Recall alone can run without one.
- **Not magic about time.** It is careful about *when* things happened — facts
  carry dates and recency affects ranking — but it cannot date something the
  source never mentioned.

## Where to go next

- **[Getting started](getting-started.md)** — running in about five minutes,
  including the config trap that catches most people.
- **[Choosing a surface](choosing-a-surface.md)** — library, REST, or MCP. This
  choice has real consequences; read it before wiring anything up.
- **[How recall works](how-recall-works.md)** — four searches, one ranking, and
  why the merge strategy turned out to matter more than the searches.
- **[Reflect](reflect.md)** — the agentic loop, and how to tell whether it
  actually ran.
- **[Multi-tenancy](multi-tenancy.md)** — three isolation models, and the one
  that is genuinely enforced by the database.
- **[Evaluation](evaluation.md)** — how the numbers above were produced, and how
  to reproduce or disbelieve them.
