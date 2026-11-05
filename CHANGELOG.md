# Changelog

All notable changes to this project are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] — 2026-11-05

### Fixed

- Foresight now requires Elixir `~> 1.19`, matching its required dependency
  `llm_toolkit`. 0.3.0 declared `~> 1.18`, and on Elixir 1.18 with Erlang/OTP 28
  it did not compile: OTP 28 represents compiled regular expressions as
  references, and Elixir 1.18 cannot embed a module attribute that holds them
  inside a collection (`Foresight.Recall.QueryAnalyzer` keeps its month patterns
  in a list). Elixir 1.19 can, so the fix needed no code change. On OTP 27,
  0.3.0 compiled as released.
- The package's `.pyc` exclusion pattern never matched, so stray Python bytecode
  under `priv/python` could have shipped. It now matches.

### Changed

- `mix foresight.labeling.judge --route dgx` defaults `FORESIGHT_DGX_BASE_URL` to
  `http://localhost:11434/v1` instead of a fixed LAN address. Set the variable to
  point at a remote GPU host.
- `mix foresight.labeling.generate` sets the display name of the label bank it
  creates or updates to "<dataset> relevance labels", replacing an internal
  project label. Bank ids and labels are unchanged.

## [0.3.0] — 2026-10-15

### Added

- `Foresight.delete_memory/4` and `DELETE /v1/default/banks/:bank_id/memories/:memory_id`
  delete one memory unit (a Foresight extension; Hindsight only clears a bank or
  deletes a document). Deleting a source fact also deletes the observations
  consolidated from it and sends their other sources back to consolidation;
  deleting an observation sends its sources back. Entity mention counts are
  retracted, links are removed, and a `delete_memory` row is written to the
  mutation audit log. Returns `memory_id`, `memory_units_deleted` and
  `observations_deleted`; an unknown or malformed id is `not_found`.
- Every recall response now carries `"stats"`: fused candidate count, the rerank
  window in force, how many candidates were reranked, how many results survived,
  and retrieval, rerank and total milliseconds. The HTTP recall response passes
  it through. The trace remains opt-in.
- New bank config field `recall_semantic_floor` (default `0.3`): the
  cosine-similarity floor the semantic arm applies before fusion, previously a
  compile-time constant. Numeric or numeric-string values in `[0, 1]` are
  honoured; anything else falls back to the default. The trace's
  `semantic_similarity_floor` reports the value in force.

### Changed

- Recall no longer holds the tenant's database connection while the embedder and
  the reranker run. Under Mode C a scope is a checked-out connection (`SET ROLE`)
  and the pool's checkout timeout (15 s by default) counted everything inside it,
  so a cross-encoder taking several seconds on a large bank turned into a dropped
  connection and an HTTP 500 instead of a slow recall. Recall now runs as three
  scoped phases (bank config, retrieval, result enrichment) with the model calls
  between them. Mode A, which has no scope, is unchanged; a recall issued from
  inside an existing scope (reflect's observation search) stays inside it.
- `list_memories` and `list_documents` page in SQL (one `COUNT` plus one
  `LIMIT`/`OFFSET` read per page) instead of loading every row in the bank and
  slicing in memory, which made paging O(pages × rows). `list_memories` with the
  Foresight-only `scope_keys` or `min_score` filters keeps the in-memory path, as
  those are derived from the mapped response. A negative `limit` or `offset`
  now clamps to 0.
- The local sentence-transformers embedder honours a per-call `model_id`, so a
  bank's `embed_model`/`embedding_dim` configuration works with
  `Embedders.SentenceTransformers` as it already did with the remote embedder. Previously the Python worker always used the engine default, so a
  bank config `PATCH` to a different local model failed with "configured
  embedding_dim … does not match active embedder dimension", and when the engine
  default already was the target model the pin was never reset and no backfill
  was enqueued. The Python worker now caches loaded models per model id (up to
  four embedders and two rerankers, least recently used evicted) instead of
  holding one slot, so banks on different models do not reload on every
  alternation. A per-call `reranker_model_id` is honoured the same way.
- Retain fact extraction takes an optional wall-clock deadline and a bounded
  chunk concurrency: engine options `retain_extraction_deadline_ms` (default nil,
  unbounded) and `retain_extraction_concurrency` (default 1, sequential), also
  `FORESIGHT_RETAIN_EXTRACTION_DEADLINE_MS` / `FORESIGHT_RETAIN_EXTRACTION_CONCURRENCY`
  under the full-ML profile. Once the deadline has elapsed, items and chunks not
  yet started are stored as-is, counted in `extraction.fallback_items`, and
  reported through the `[:foresight, :retain, :extraction_fallback]` telemetry
  event with reason `:deadline`; a chunk already in flight finishes or hits the
  LLM timeout. With concurrency above 1 the chunks of one item extract in
  parallel in stable order, so a long session costs the slowest chunk rather than
  the sum, and the LLM usage recorded inside the parallel calls is folded back
  into the retain's `usage`. Defaults leave the previous sequential, unbounded
  behaviour in place.
- The embeddings backfill entry point (`Embeddings.Backfill.run/3`) loads the
  storage module before checking for `backfill_embeddings/3`, so an in-process
  call ahead of the first storage use no longer reports `not_implemented`.
- The recall guide documents the rerank window default (2× the recall budget, or
  `recall_rerank_window`), the cost of heavy cross-encoders over it, and the
  reranker choice for abstract corpora (`BAAI/bge-reranker-v2-m3` lifted hit@1
  from 13/20 to 18/20 on a labelled paraphrase set where MS MARCO MiniLM flattens
  paraphrase and off-topic text to the same logit).

### Fixed

- The sentence-transformers reranker worker now always returns raw cross-encoder
  logits. `CrossEncoder.predict` applies the model's default activation, which is
  `Identity` for e.g. `cross-encoder/ms-marco-MiniLM-L-6-v2` but `Sigmoid` for
  models such as `BAAI/bge-reranker-v2-m3`; the Elixir reranker then applied its
  own sigmoid, so with sigmoid-default models every pre-boost `rerank_score` was
  squeezed into `(0.5, 0.73)`: the conventional cutoffs at or below 0.5 kept
  everything, and strongly negative logits (below about −13) rounded to exactly
  0.5, erasing the distance between an off-topic candidate and a weak match. The
  worker now pins an `Identity` activation through the sentence-transformers >= 4
  constructor (`priv/python/requirements.txt` now requires `>=4`; the worker's
  `model_kwargs` argument already needed it), so
  `raw_rerank_score` is a logit and `rerank_score` is sigmoid(logit) for every
  model; `device_info` reports the activation as `reranker_activation`. Ranking
  order is unchanged. **Upgrade note:** with a sigmoid-default model a `min_score`
  of 0.5 used to let nearly everything through; it now drops every result whose
  pre-boost logit is negative (the recall boosts, up to ±25%, still apply on top).
  Re-measure any `min_score` you set under 0.2.1 for such a model. Default installs
  (`Passthrough`, or `cross-encoder/ms-marco-MiniLM-L-6-v2`) see no change.

## [0.2.1] — 2026-10-13

Package hygiene. No behaviour changes.

- Removed internal issue-tracker references from every shipped file: migration
  comments, the Python requirements file, and the default artifact paths of the
  `foresight.labeling.*` mix tasks (now `tmp/labeling/gold.json`,
  `tmp/labeling/pools.json`, `tmp/labeling/judge-prefilled.json`, ...). The kappa
  task's default bank is now `d2-longmemeval-s`, matching the generate task.
- Consumers that omit the optional `bumblebee`, `nx`, `tokenizers`, `erlport` or
  `llm_core` dependencies no longer see "module is undefined" compiler warnings
  from the library; those modules are listed as xref exclusions.
- Install snippets in the README and guides read `~> 0.2`; the evaluation guide
  links to the bench write-up on GitHub, since `docs/` is not part of the package.

## [0.2.0] — 2026-10-12

The "workhorse" release: every open defect, question mark and missing feature that
stood between Foresight and dependable production use, closed in one sweep. Two new
tenant migrations ship (run `Foresight.Migrations.install/2` and re-provision or
reconcile Mode C tenants as usual); every public result shape is extended, none is
broken.

### Fixed

- **Concurrent consolidation could duplicate observations.** Two overlapping
  `consolidate` runs for one bank read the same pending facts and both wrote.
  Every chunk now applies under a per-bank-and-scope advisory lock, re-checks under
  that lock that its facts are still pending and that the pooled observations it
  merged against are unchanged, and otherwise defers the chunk (`chunks_deferred`
  on the result) so the next round re-plans from committed state. The Oban worker
  declares uniqueness per bank and payload, so a second enqueue while one is in
  flight returns the existing job.
- **Consolidation ignored the slot cap until after the fact.** The merge prompt now
  carries Hindsight's capacity note when a scope is at or near
  `max_observations_per_scope`, and the response schema caps `creates` to the
  remaining slots, instead of only truncating the model's output.
- **Model output was stored unsanitised.** Control characters, DEL and invalid
  UTF-8 in extracted facts and merged observations are stripped
  (`Foresight.Text.Sanitize`), as Hindsight does.
- **Banks on 1536-dimension embeddings never got semantic memory links.** Link
  construction knew only the 384 and 1024 columns, so their graph arm stayed dark.
  It now follows the bank's embedding profile for every width.
- **`FakeStorage` scored temporal recall by `mentioned_at`.** The test double now
  mirrors Storage.Ecto's precedence (`occurred_end`, `occurred_start`,
  `occurred_at`, then `mentioned_at`) and persists the occurred fields it is given.
- **The reflect `expand` tool ignored `depth` and trusted the model's id list.**
  `"chunk"` returns provenance plus the neighbouring chunks of the same document,
  `"document"` the owning document's title and text; ids are de-duplicated,
  validated and capped at 25. Reflect refuses an asynchronous agent pipeline up
  front, since grounding is accumulated in the calling process.
- **Unbounded free-form JSON on retain items.** `metadata` over 64 KiB or
  `source_location` over 16 KiB (encoded) is rejected as `:invalid_request` before
  anything is written.
- **Test harness.** `PostgresHarness.cleanup_stale!/0` only removes instances whose
  postmaster is gone; it used to wipe every harness instance on the machine, so two
  runs destroyed each other's database.

### Added

- **Auditable usage on retain and recall.** When an operation makes a chargeable
  call, its result carries `"usage"`: token totals plus one entry per call with
  kind (`llm` or `embedding`), pipeline role (`extract`, `consolidate`), provider,
  model, endpoint host for remote embeddings, request id when the provider returned
  one, unit count, and status (failed calls are listed with zero tokens and counted
  in `failed_calls`). Local embedders and the Noop LLM record nothing, so `"usage"`
  stays `nil`/absent for them. The HTTP retain and recall responses carry it.
- **3072-dimension embeddings** (OpenAI text-embedding-3-large at full width) via a
  `halfvec(3072)` column with a halfvec HNSW index; pin a bank with
  `"embedding_dim" => 3072`. Requires pgvector 0.7.0 or newer; the migration says so
  if it is older. Tenant migration `20261012120000`.
- **Mental models at Hindsight parity.** `search_mental_models` ranks a bank's
  mental models by embedding similarity to the query (embeddings are kept in a new
  `mental_model_embeddings` table and refreshed lazily when content or the bank's
  embedding profile changes; lexical ranking remains the fallback), honours
  `max_results`, and reports per model `relevance`, `updated_at`, `is_stale` and
  `staleness_reason`. Staleness means a memory in the model's scope (its tags under
  `trigger.tags_match`, its `trigger.fact_types`) was written after
  `last_refreshed_at`; a never-refreshed model is stale. The most relevant models
  are pre-seeded into the agentic reflect opening context, and `get_mental_model`,
  `list_mental_models` and `update_mental_model` report the computed verdict.
  Tenant migration `20261012121000`.
- `Foresight.Reflect.Expand`, `Foresight.Reflect.MentalModels`, `Foresight.Usage`,
  `Foresight.Text.Sanitize`, `Foresight.Reflect.LoopOptions`.

## [0.1.5] — 2026-10-12

### Fixed

- **`update_mode: "replace"` no longer rebuilds every entity in the bank.** Any
  replace (and `delete_document`, `update_document`, `clear_observations`,
  `clear_memory_observations`) used to delete all entities and links in the bank
  and re-derive them from stored text with the regex extractor: O(bank) per
  call, and LLM-extracted entities and their name embeddings were lost for good.
  These paths now retract only the deleted units' mentions: mention counts and
  co-occurrence weights are decremented, exhausted links dropped, and entities
  nobody mentions any more pruned. Entities the surviving units mention keep
  their identity, type, and embedding. `replace` is still opt-in, as in
  Hindsight, but it is no longer expensive or lossy.
- **Concurrent retains of one `document_id` are safe.** The document upsert is a
  single `INSERT ... ON CONFLICT DO UPDATE`; the former read-then-write pair
  raised `Ecto.ConstraintError` (HTTP 500) for the loser of a concurrent first
  insert. Replace mode takes a transaction-scoped advisory lock per document, so
  overlapping replaces serialise and leave exactly one set of memory units.
  `delete_document` and `update_document` take the same lock before touching the
  document, and a batch upserts its document rows in a stable order, so no pair of
  these writers can deadlock with each other. Post-commit link construction can
  still cross a concurrent replace or delete of the units it links to; Postgres
  then aborts one side, and the retain or document write is retried instead of
  failing with `deadlock_detected`. `delete_document` and `update_document`
  re-read the document under the lock, so a row deleted by a concurrent writer
  yields `:not_found` rather than `Ecto.StaleEntryError`. `Document.changeset/2`
  declares the unique constraint.
- **Co-occurrence link weights start at 1.** A fresh `EntityLink` struct's
  schema default made the first co-occurrence of a pair count as 2.
- **A failed recall normalisation returned the timing wrapper.** Rejected
  payloads (an unsupported field, a bad `min_score`) came back as
  `{{:error, _}, ms}` instead of `{:error, %Foresight.Error{}}`.
- **Retain extraction fallback is fully reported and no longer leaks.** A model
  response that was valid JSON but not a facts list fell back to storing the
  raw text with no log line and no telemetry; it now reports like every other
  fallback. The warning names only the failure kind: the raw reason, which for
  a structured-output failure carries facts the model derived from the user's
  text, is no longer written to the log. Telemetry handlers still receive it,
  plus a `reason_kind`.
- **The regex entity extractor no longer reads `When` and `Involving` as
  entities.** Stored facts are assembled as `what | When: x | Involving: y`, and
  the capitalised labels matched the entity pattern on every fact.
- **Cross-encoder scores are no longer NaN on CPU.** transformers 5.x leaves
  CPU weights backed by the memory-mapped checkpoint; on macOS/arm64 a forward
  pass over those tensors bus-faults or returns NaN for every pair (reproduced
  with torch 2.10 and 2.13, transformers 5.8 and 5.13) while MPS is correct. The
  Python worker now copies CPU-resident weights into ordinary tensors after
  loading, and refuses to return non-finite scores or vectors (a clean error
  instead of the erlport protocol failure a NaN used to cause). The Elixir
  reranker fails closed on a non-numeric score.

### Added

- **`score` on every recall result, and an optional `min_score` cutoff.**
  Both are Foresight extensions to the Hindsight recall contract. `score` is the
  reranked, boosted score the results are ordered by; `min_score` (a
  non-negative number) drops results below it after boosting and before the
  token trim. `after`, `before`, `limit`, and `offset` stay rejected.
- **`extraction` on the retain result**: `%{"enabled", "mode",
  "fallback_items", "empty_items"}`. `fallback_items` counts items stored as raw
  text because extraction errored; `empty_items` counts items stored raw
  because extraction found no facts. The HTTP retain response carries it. It
  describes the synchronous write: an async retain answers with operation ids,
  and the report is on the completed operation's result. The
  `[:foresight, :retain, :extraction_fallback]` telemetry event fires once per
  failed chunk, so its count can exceed `fallback_items`, which counts items.
  The MCP `recall` tool schema declares `min_score`.
- **`Foresight.Retain.FactExtraction.extract/2`** returns `{items, stats}`;
  `maybe_extract/2` is unchanged.

## [0.1.4] — 2026-10-05

### Added

- **Text-body documents in `retain_files`.** A file given as `%{"text" => body}`
  (or a bare binary) is retained as-is by a dedicated text converter,
  bypassing the configured converter and never reading a `"path"`. This is the
  shape a Hindsight migration carries by construction. Without a `"document_id"`
  or `"filename"` the document gets a content-addressed id (`text:<sha256>`), so
  single-file calls cannot collide on `file-0`. Pass `"request" => %{"async" =>
  false}` for a synchronous write. Request options are read with
  string keys; atom keys are ignored.
- **Blank text bodies are rejected**, not silently dropped: retain discards
  items with no alphanumeric content, which would make a blank document vanish
  from a copy without trace.
- **`update_mode` passthrough** on `retain_files` (per file or in `"request"`).
  Re-retaining a `document_id` upserts the document but, by default, appends a
  second set of memory units. `"update_mode" => "replace"` deletes the prior set
  but also rebuilds every entity in the bank on each call, so it is opt-in only;
  bulk copies should rely on their own once-only ledger. Large text bodies are
  retained as a single unchunked memory unit: pre-chunk them.

### Documentation

- **`config :foresight, backend:` is now documented** in the getting-started
  guide, whose "working configuration" omitted it and so left new consumers on
  the Noop backend. Use `backend: Foresight.Backend.Store`;
  `storage: Foresight.Storage.Ecto` belongs under `engine:` and lacks
  `retain_files/3` as a backend.

### Fixed

- **`update_mode: "replace"` raised on any document that already had memory
  units** (`Postgrex expected a binary of 16 bytes` in `affected_observation_ids`):
  the source-unit id array is now bound with an explicit `{:array, Ecto.UUID}`
  type. The path had no Postgres coverage before.
- **`update_mode: "replace"` now releases sibling units for reconsolidation.**
  Units that fed an observation deleted by the replace were left marked
  consolidated; they are reset as `delete_documents` already did.

## [0.1.3] — 2026-09-28

### Changed

- **Trademark acknowledgment in the README.** Upstream Hindsight now carries
  a claimed trademark mark alongside a commercial cloud offering. Foresight
  is an independent port and is not affiliated with, endorsed by, or
  sponsored by Vectorize AI, Inc.; references to Hindsight serve attribution
  (the MIT notice in `LICENSE`, unchanged since 0.1.0) and interoperability
  description only. No code changes.

## [0.1.2] — 2026-09-28

### Fixed

- **`Foresight.Migrations.install/2` no longer collides across BEAMs.** The
  scratch directory used to materialize control-plane migrations was named with
  `System.unique_integer/1`, which is unique only within a single BEAM. Two VMs
  sharing a `TMPDIR` — a release beside a migration task, concurrent cold boots,
  CI jobs on a shared volume — could land on the same path and silently load
  each other's partial link trees. Scratch directories are now allocated under
  cryptographically random names with an exclusive `mkdir` (retried on the
  astronomically unlikely collision), partial link trees are removed on failure,
  and stale directories left by another BEAM are ignored.

## [0.1.1] — 2026-09-27

### Added

- `Foresight.Migrations.install/2`, an idempotent in-BEAM installer for packaged
  control-plane migrations using the collision-safe
  `foresight_schema_migrations` ledger.
- `Foresight.Tenancy.provision_mode_c_schema/4`, the supported role-neutral
  consumer seam for installing the control plane and provisioning a tenant
  schema without creating roles or tenant keys.
- An exhaustive packaged-migration classification manifest.
- Automatic adoption of structurally verified 0.1.0 control-plane migrations
  into the dedicated Foresight ledger.

### Fixed

- Explicit per-call `rls_enabled: false` now reaches every Ecto tenant scope,
  parallel recall strategy, nested reflect helper, and applicable async worker
  instead of being replaced by the application default.
- Tenant webhook discovery and delivery creation now execute inside the same
  RLS scope as the operation that emitted them.

## [0.1.0] — 2026-09-07

Initial public release, published as `foresight_memory`.

Foresight is an Elixir port of Hindsight (MIT, Vectorize AI, Inc.). The ported
architecture is theirs and is attributed in the README (Provenance) and the
LICENSE (third-party notice); divergence from it is documented where introduced.
Everything below predates the first publish and is part of the 0.1.0 story.

### Changed

- **Recall fusion now defaults to `:normalized` / `:zscore`** (was `:rrf` /
  `:min_max`). Measured over 134 graded-relevance queries: +0.1009 nDCG@10, 95%
  CI [0.0597, 0.1476], and MRR 0.776 → 0.903. `:rrf` merges on rank position and
  discards the arm scores; normalizing keeps them. Existing banks with an
  explicit `recall_fusion` override are unaffected.
- **Default reranker is now `Rerankers.Passthrough`** (was `Rerankers.Bumblebee`).
  The old default made a bare install demand the Nx/Bumblebee/EXLA stack and fail
  its capability preflight, so Foresight could not boot without ML dependencies
  nobody had asked for.

### Fixed

- **Foresight is installable.** `:plug` and `:llm_core` were declared
  `optional: true` while being referenced unconditionally at compile time, so
  `{:foresight, "~> 0.1"}` on its own failed `mix compile`. `:plug` and the new
  direct `:llm_toolkit` are now required; `:llm_core` remains optional and its
  adapter is guarded, with a stub that names the missing dependency.
- **Recall trace reports the fusion algorithm actually in use.** It was hardcoded
  to `"rrf"` and reported the wrong algorithm on every request once the default
  changed.
- **MCP:** `async_processing` accepted as an alias for `async`; fabricated
  lenient sessions are closed at the end of the request that created them;
  undeclared tool arguments are named in the log instead of being dropped.
- **Enqueueing without Oban** returns a structured `:unavailable` error instead
  of raising.
- **Scrivener ingestion:** path traversal via an unvalidated bundle UUID, escape
  via symlinked path components, and unbounded reads from non-regular files are
  all closed.

### Security

- Mode C schema-per-tenant isolation verified under a genuine least-privilege
  role (`rolsuper = false`, RLS forced): five forged-header cross-tenant attacks,
  5/5 blocked, verified by canary rather than status code.

## [0.1.0]

Initial development version.
