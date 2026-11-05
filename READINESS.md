# Foresight readiness

Last updated: 2026-08-14

This document exists for the first consumer. It states plainly what Foresight is
ready for, what it is not, and which claims are measured versus assumed. Where a
number appears, the method that produced it appears with it.

Read this before the README. The README describes how to run the thing; this
describes whether you should.

---

## Headline

**Foresight is at statistical parity with Python Hindsight, and is ready to be
depended on. It does not measurably exceed Hindsight, and no claim in this repo
should be read as saying it does.**

Parity is the shipping bar we chose deliberately. Work that might push past it
exists, is scoped, and is deferred.

---

## What "parity" means here, exactly

The claim rests on a matched-reader benchmark, both arms atomizing, n=30×3 on
LongMemEval-S:

| arm | reflect accuracy |
| --- | --- |
| Hindsight (Python, reference) | 0.711 (SD 0.038) |
| Foresight (Elixir) | **0.800** (SD 0.033) |

Δ +0.089 (SD 0.069). McNemar p = 0.227 / 1.000 / 0.774 across three replications —
**not significant in any of them**, and the mean delta sits *inside* the ±0.1
nondeterminism band for n=30. The point estimate favours Foresight; the test does
not support calling that a lead. Treat the two as equivalent.

Measured 2026-08-14, gpt-4o-mini both arms, gpt-4o judge, seed 42, n=30, three
replicates, with the `:normalized`/`:zscore` fusion default in place. Foresight's
own level rose from 0.708 in July while Hindsight moved 0.686 → 0.711 (inside its
own noise), so the library improved and the scoreboard still reads parity.

The single most important number here is the spread: the delta ranged +0.034 to
+0.166 **across identical configuration**. Any single run of this benchmark can be
made to say almost anything.

This matters because it did not start there. The same benchmark once showed
Foresight at 0.467 against Hindsight's 0.733 — a real, significant deficit. That
deficit was closed by one cluster of fixes in `retain` extraction (chunking, the
`When:` clause, temporal offsets), which is why the attribution is quoted rather
than a general "we improved things".

### What is NOT measured

- **No exceed result exists.** The three-replicate head-to-head above is the
  strongest evidence available and it says parity. Per-bank learned fusion
  weights were also re-measured properly at n=150 with query-level splits and
  came out at +0.0153 nDCG@10 (SD 0.0275, negative in 3 of 12 splits) — not
  significant, not shipped.
- **What DID measurably improve is recall ranking, not answer accuracy.** The
  fusion default moved from `:rrf` to `:normalized`/`:zscore` on +0.1009 nDCG@10
  (95% CI [0.0597, 0.1476], 12/12 splits positive, 134 labelled queries). That is
  a ranking metric on one corpus with machine-anchored labels — it did not
  translate into a significant answer-accuracy lead, and this document does not
  claim it did.
- **Consolidation and recall improvements are unmeasured, not unproven.** The
  n=30 answer-judge lane hit its sensitivity ceiling: a consolidation change that
  produced +52% observations moved the score 0.711 → 0.708, i.e. nothing. Those
  changes shipped as correctness wins with no eval-lift claim attached.

---

## Label provenance — read this before trusting any eval number

**Gold labels in this repo are agent-anchored, not human-graded.** This is a
standing posture, adopted deliberately because human grading capacity was not
available, and it is stated here rather than buried.

Practically:

- Labels carry `source: :agent` — a provenance distinct from `:human` on purpose,
  so nothing can later mistake one for the other.
- LLM-judged labels carry `source: :llm` and stamp `judge_model` as
  `"<model>@<rubric-version>"`, derived from the rubric actually sent. There is
  deliberately no caller override for that field: one existed, and it allowed a
  label to claim a rubric version the judge never saw.
- Agreement is gated on Cohen's quadratic-weighted kappa ≥ 0.6 before labels are
  accepted.

If you need human-anchored ground truth for a regulatory or publication claim,
this repo does not have it, and the trust gate does not manufacture it.

---

## Which surface to use

Three surfaces exist. They are **not** equal, and the ordering is a
recommendation, not a formality.

### 1. In-BEAM library — recommended

Take `foresight` as a dependency and call it directly. No serialization, no
session lifecycle, no transport error class, and errors arrive as
`Foresight.Error` structs you can pattern-match. Everything below is a wrapper
over this.

The supported database setup seam is now consumer-owned and release-versioned:

```elixir
{:ok, _} = Foresight.Migrations.install(MyApp.Repo)

{:ok, _tenant} =
  Foresight.Tenancy.provision_mode_c_schema(
    MyApp.Repo,
    tenant_id,
    prefix,
    rls_enabled: true
  )
```

The installer uses a Foresight-owned migration ledger and cannot silently treat
a colliding host migration version as applied. The Mode C wrapper is
role-neutral: role and tenant-key creation are not hidden side effects.

The package contract is checked from a throwaway Mix project built only from
the unpacked Hex artifact. `:plug` and `:llm_toolkit` are required dependencies;
`:llm_core` remains optional because its adapter is compile-time guarded.

```elixir
# mix.exs
{:foresight, "~> 0.1", hex: :foresight_memory}
```

```elixir
# config/config.exs — minimal in-BEAM consumer, no HTTP/MCP/Oban/local ML
config :foresight,
  engine: [
    embedder: Foresight.Embedders.Noop,
    reranker: Foresight.Rerankers.Passthrough
  ],
  http: [enabled: false],
  mcp: [enabled: false],
  oban: [enabled: false],
  repo: [enabled: false],
  file_ingestion: [enabled: false]
```

Note the nesting: `embedder` and `reranker` live under `engine:`. Setting them at
the top level silently does nothing, and the failure surfaces later as a preflight
error about `:nx` rather than as a config error.

The capability preflight itself is good — it refuses to boot with a specific,
actionable message (`optional dependency :nx is not available`) rather than
failing deep in a request. Expect to meet it while narrowing the config down.

If you enable the `llm_core` adapter, its own application startup behavior and
configuration become part of your runtime.

### 2. REST — 67 routes, recommended if you need a network boundary

A full surface (`/v1/:tenant/banks/...`) covering banks, memories, recall,
reflect, observations, mental models, operations, directives, import/export.
Well-trodden; this is what the benchmark harnesses drive.

### 3. MCP — 11 tools, works, but understand what you are choosing

Every defect found in the July/August spike is fixed: the server boots in the
right order, a bad tool call can no longer take the process down, `list_banks`
(the usual health probe) answers its own valid call, `retain` no longer silently
requires Oban, and the handshake gap is bridged.

Two structural properties survive the fixes and are worth knowing:

- **One Hermes.Server.Base GenServer owns every live session.** The reachable
  crash paths are closed and tested, but a raise originating outside the tool
  path would still affect all sessions. That is a property of the architecture,
  not of any remaining bug.
- **`lenient_session: true` is opt-in and default OFF.** Consumers ported from
  Python Hindsight that post bare `tools/call` with no MCP handshake need it.
  With it off they get `Server not initialized`. Fabricated sessions are torn
  down per request rather than held for the idle timeout, so this no longer
  accumulates session processes under load.

Argument-name compatibility with Python Hindsight is handled: `async_processing`
is accepted as an alias for `async`, and an explicit `async` wins over the alias
rather than being overwritten by it. Undeclared arguments are named in the log
instead of vanishing silently.

---

## Security posture

**Mode C (schema-per-tenant) has been run under a genuine least-privilege role
and proven, not assumed.**

- The application role is `rolsuper = false`. This matters: RLS is not enforced
  against a superuser, so any isolation claim made while connected as one is
  vacuous.
- Tenant tables carry both `ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY`.
- Five forged-header cross-tenant attacks were run over real HTTP against a live
  instance. **5/5 blocked**, verified by grepping for the victim's canary string
  in the attacker's responses rather than by trusting status codes.
- The proof script exits **2 (INCONCLUSIVE)** rather than 0 if it cannot confirm
  its own self-check — a green run means the test could have failed.

Setup is genuinely fiddly and gets it wrong in five distinct ways.
[The Mode C least-privilege runbook](guides/mode-c-least-privilege.md) documents the requirements in the order they
actually failed, with the real error strings.

The posture monitor compares against the connection's own login role rather than
a hardcoded `postgres`, which previously made the least-privilege posture
structurally unreportable.

---

## Known gaps

Things a consumer could reasonably expect that are absent or deferred:

| gap | status |
| --- | --- |
| Forced hierarchical retrieval in reflect | **Blocked upstream.** `tool_choice` is absent from `llm_core` 0.5.0 entirely, so forced-tool retrieval is not currently expressible. Needs an upstream change + republish. |
| Recall-pool tuning (`ef_search`, rerank window) | Scoped, unshipped. Deferred until a sensitivity-adequate eval exists. |
| Reflect-loop restructuring | Scoped, unshipped, and **risk-flagged** — a previous attempt regressed. |
| Human-graded gold labels | Not present by decision. See label provenance above. |
| Exceed over Hindsight | Not demonstrated. See headline. |

None of these block the in-BEAM or REST surfaces.

---

## Verifying this yourself

```bash
mix ci
```

Runs format check, `compile --warnings-as-errors`, three architectural fitness
gates (namespace purity, tenancy boundary, isolation coverage), and the suite:
**993 tests, 0 failures**.

The fitness gates fail the build rather than warn. `isolation_coverage`
specifically fails if the tenant-isolation tests are tagged out or if the suite
is empty — an excluded isolation suite is indistinguishable from a passing one
otherwise, which is exactly how this class of test dies quietly.

For the security claim specifically:

```bash
VICTIM_API_KEY=... elixir scripts/mode_c_isolation_proof.exs
```

Exit 0 = attacks blocked and the self-check confirmed. Exit 2 = inconclusive,
do not read it as a pass.
