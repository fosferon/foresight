# Getting started

## Install

```elixir
# mix.exs
def deps do
  [{:foresight, "~> 0.3", hex: :foresight_memory}]
end
```

That is the whole dependency line. The `hex:` option is there because the package is
published as **`foresight_memory`** — the plain name belongs to an unrelated library on
hex. Nothing else is affected: the application is `:foresight`, the modules are
`Foresight.*`, and you write `alias Foresight` as you would expect.

Foresight compiles and boots with no configuration at all — you can verify that
before writing any config:

```elixir
{:ok, _pid} = Foresight.Supervisor.start_link(name: :foresight)
```

This is worth stating explicitly because for a long time it was not true. The
HTTP modules referenced `plug` while declaring it optional, so a bare install
failed with a `CompileError`, and the default reranker demanded the whole
Nx/Bumblebee stack, so even after compiling it would not start. Both are fixed,
and there is a test in the default suite that fails if either regresses.

With no configuration you get an in-memory-free, LLM-free skeleton: it starts,
but it cannot embed, rerank, or store anything. Useful for confirming the wiring
and not much else.

## A working configuration

Memory needs somewhere to live. Foresight uses PostgreSQL with
[pgvector](https://github.com/pgvector/pgvector).

```elixir
# config/config.exs
config :foresight,
  repo: [enabled: false], # MyApp supervises MyApp.Repo
  backend: Foresight.Backend.Store, # what Foresight.retain/3 and friends route to
  ml: [enabled: true], # supervises the local embedding serving the Bumblebee embedder calls
  engine: [
    storage: Foresight.Storage.Ecto, # what the backend stores through
    repo: MyApp.Repo,
    embedder: Foresight.Embedders.Bumblebee,
    reranker: Foresight.Rerankers.Passthrough,
    llm: Foresight.LLMs.LlmCore
  ]

# Configure MyApp.Repo normally in your host application.
```

```elixir
# mix.exs — capabilities you enable, you must also depend on
{:bumblebee, "~> 0.7"}, {:nx, "~> 0.12"}, {:exla, "~> 0.12"},  # local embeddings
{:llm_core, "~> 0.5"}                                          # LLM access
```

Then install the Foresight control plane through your Repo during deployment:

```elixir
{:ok, %{migrated_versions: _}} = Foresight.Migrations.install(MyApp.Repo)
```

Do **not** copy the packaged files into the host migration directory or assume
plain `mix ecto.migrate` will install them. `install/2` resolves the files from
the installed Foresight application, selects only control-plane migrations, and
uses the dedicated `foresight_schema_migrations` ledger. It is safe to call on
every deploy and returns an empty version list when already current. When
upgrading from 0.1.0, it adopts the old shared-ledger installation only after
verifying the complete 0.1.0 version set and its control and tenant tables.

For Mode C, install the control plane and provision a tenant in one call:

```elixir
{:ok, tenant} =
  Foresight.Tenancy.provision_mode_c_schema(
    MyApp.Repo,
    "tenant-123",
    "tenant_acme",
    rls_enabled: true
  )
```

The explicit boolean is required. This role-neutral seam does not create a
database role or an HTTP tenant key. `public` is reserved for the host
application and is rejected as a Mode C tenant prefix.

### Two layers: `backend:` and `engine: [storage:]`

`Foresight.retain/3`, `recall/3` and every other top-level function route to the
module named by `config :foresight, backend:`. The package default is
`backend: Foresight.Backend.Noop`, which answers every call with
`{:error, %Foresight.Error{reason: :not_implemented}}` — so a configuration with
no `backend:` boots cleanly and does nothing.

Set **`backend: Foresight.Backend.Store`**. The store is the operation layer: it
converts uploaded files (`retain_files/3`), applies request defaults, and then
calls the storage module you name under `engine: [storage: …]`
(`storage: Foresight.Storage.Ecto`, the only shipped storage).

Do **not** set `backend: Foresight.Storage.Ecto`. The storage module
exposes most of the same functions, so many calls appear to work (the store is what
supplies defaults such as `repo:`, embedder and queue) — but file ingestion exists
only on the store, and
`Foresight.retain_files/3` then fails with
`UndefinedFunctionError: Foresight.Storage.Ecto.retain_files/3`.

```elixir
config :foresight, backend: Foresight.Storage.Ecto # ✗ no retain_files/3
config :foresight, backend: Foresight.Backend.Store # ✓
```

#### Retaining documents you already have as text

`retain_files/3` accepts text bodies directly — the shape a migration from
Hindsight carries — with no converter involved:

```elixir
Foresight.retain_files(ctx, %{
  "files" => [%{"text" => body, "document_id" => "source-id-123"}],
  "request" => %{"async" => false, "metadata" => %{"batch" => "migration"}}
})
```

- **Request options use string keys.** `%{async: false}` (atom keys) is silently
  ignored: the write stays asynchronous and the metadata is dropped.
- **Pass a stable `"document_id"`** from your source. Without a `"document_id"`
  or `"filename"` one is derived from the content (`text:<sha256>`).
- **Re-retaining a `document_id` replaces the document row but appends a second
  set of memory units** (Hindsight's default). `"update_mode" => "replace"`
  deletes the previous set first and retracts only those units' entity mentions;
  concurrent replaces of the same document are serialised.
- Blank bodies (no letters or digits) are rejected, and a large body is stored
  as a single unchunked memory: split big documents before retaining.

### Embedding widths, and what a call cost

A bank is pinned to one embedding profile (model and dimension) by its first
retain, or explicitly with `update_bank_config`. Supported dimensions are 384,
1024, 1536 and 3072. The last is stored as pgvector `halfvec` because the HNSW
index for plain vectors stops at 2000 dimensions; it needs pgvector 0.7.0 or newer,
and the migration says so if yours is older.

Retain and recall results carry `"usage"` when the operation made a chargeable
call: token totals, and one entry per call with its kind (`llm` or `embedding`),
pipeline role, provider, model, request id and status. With local embedders and no
LLM nothing is chargeable, so the key is `nil` on retain and absent on recall.

### The one trap

**`embedder` and `reranker` live under `engine:`.** Set them at the top level and
nothing happens — silently. No error, no warning; your configuration is simply
ignored and the defaults stand.

```elixir
config :foresight, embedder: MyEmbedder          # ✗ silently ignored
config :foresight, engine: [embedder: MyEmbedder] # ✓
```

The failure surfaces much later and points somewhere else entirely — usually as a
preflight complaint about `:nx`, because the ignored setting left the default in
place. If a config change appears to have had no effect, check the nesting first.

### The preflight is on your side

Enable a capability without its dependency and Foresight refuses to start, by
name:

```
** (RuntimeError) Foresight capability preflight failed:
   optional dependency :nx is not available.
   Add/fetch the dependency before enabling the related capability.
```

This is deliberate. The alternative is booting successfully and failing on the
first request that happens to need embeddings — at which point the error appears
somewhere far from its cause.

## Your first memories

```elixir
alias Foresight.Context

ctx = %Context{tenant_id: "default", mode: :mode_a, bank: "notes"}

{:ok, _} = Foresight.put_bank(ctx, "notes", %{"name" => "Notes"})

{:ok, _} =
  Foresight.retain(ctx, %{
    "items" => [
      %{"content" => "Deployed v2.3 on Tuesday. The migration took 40 minutes.",
        "context" => "ops log"}
    ]
  })

{:ok, result} = Foresight.recall(ctx, %{"query" => "how long did the migration take?"})
```

A **bank** is an isolated namespace of memory — one per agent, per user, per
project, whatever your unit of "a memory" is. Banks do not share retrieval;
searching one never returns another's contents.

The **context** carries tenant, isolation mode and bank on every call. There is
no ambient state and no "current bank": if a call touches memory, it says whose.
This is tedious for exactly as long as it takes to appreciate that no request can
accidentally read another tenant's data.

## Retain is not an insert

`retain` extracts. One paragraph typically becomes several dated facts, each
independently retrievable, with entities pulled out and linked.

That means it costs an LLM call and takes real time — and it is where quality is
won or lost. When fact extraction was subtly wrong in this library (it dropped
the `When:` clause from every stored fact), end-to-end answer accuracy sat at
**0.467**. Fixing extraction alone took it to **0.711**. Nothing about retrieval
or reasoning changed.

If you are debugging poor answers, look at what `retain` actually stored before
you look at anything else. `Foresight.list_memories/3` shows you.

## Then reflect

```elixir
{:ok, answer} = Foresight.reflect(ctx, %{"query" => "what happened with v2.3?"})
```

`reflect` needs an LLM configured. See **[Reflect](reflect.md)** for the loop it
runs and how to confirm it did.
