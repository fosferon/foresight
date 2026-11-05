# Foresight

[![CI](https://github.com/fosferon/foresight/actions/workflows/ci.yml/badge.svg)](https://github.com/fosferon/foresight/actions/workflows/ci.yml)
[![Hex pm](https://img.shields.io/hexpm/v/foresight_memory.svg)](https://hex.pm/packages/foresight_memory)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/fosferon/foresight/blob/main/LICENSE)

Semantic memory for Elixir: retain what happened, recall what's relevant,
reflect on what it means — in the BEAM, next to your application.

Foresight is an Elixir port of [Hindsight](https://github.com/vectorize-io/hindsight),
and it is **measured against** the original rather than described in relation to it:
three matched-reader replicates put the two at statistical parity (reflect 0.800 vs
0.711, McNemar not significant in any replicate). Nothing in this repository should
be read as claiming parity was exceeded. See [Provenance](#provenance) below, and
read [`READINESS.md`](READINESS.md) before depending on this — it states what is
measured, what is assumed, and which surface you should actually use.

## Installation

```elixir
def deps do
  [{:foresight, "~> 0.3", hex: :foresight_memory}]
end
```

Foresight requires Elixir 1.19 or later, on Erlang/OTP 27 or 28.

The package is published as `foresight_memory` (the plain name is taken on hex by an
unrelated package); the application and modules are `Foresight`. Foresight compiles
and boots with no configuration; capabilities are opt-in with their dependencies.

When Foresight shares your application's database, install its control plane through
your Repo rather than copying migrations or running Foresight files in your host
`schema_migrations` namespace:

```elixir
{:ok, _} = Foresight.Migrations.install(MyApp.Repo)
```

The installer uses the migrations shipped in the Hex package, runs only Foresight
control-plane migrations, and tracks them separately in
`foresight_schema_migrations`. For schema-per-tenant deployments, provision each
role-neutral schema with
`Foresight.Tenancy.provision_mode_c_schema(MyApp.Repo, tenant_id, prefix,
rls_enabled: true)`. That seam creates neither database roles nor tenant API keys.
See [Getting started](guides/getting-started.md) and
[Multi-tenancy](guides/multi-tenancy.md).

## Three surfaces

In recommended order:

- **In-BEAM library** — take `foresight` as a dependency and call it directly.
  `Foresight.Supervisor` is the embeddable supervision entry point; errors arrive as
  `Foresight.Error` structs. Everything else is a wrapper over this.
- **REST** — 67 routes under `/v1/:tenant/banks/...` covering banks, memories,
  recall, reflect, observations, mental models, operations, and import/export.
- **MCP** — 11 tools over Hermes streamable-HTTP. Works; see
  [`READINESS.md`](READINESS.md) for the two structural properties to understand
  before choosing it.

Optional dependencies (HTTP / ML / Repo / Oban) are declared in `mix.exs` with their
runtime capabilities disabled by default in `config/config.exs`, so an embedding
consumer pays only for what it enables. The two that are required at compile time
(`:plug`, `:llm_toolkit`) are carried for you.

## Documentation

The [full documentation](https://hexdocs.pm/foresight_memory/) is written as a
manual, not a file listing:

- [Overview](https://hexdocs.pm/foresight_memory/overview.html) — the three verbs
  (`retain`, `recall`, `reflect`) and what Foresight is honestly good at.
- [Getting started](https://hexdocs.pm/foresight_memory/getting-started.html) —
  running in about five minutes, including the config trap that catches most people.
- [Choosing a surface](https://hexdocs.pm/foresight_memory/choosing-a-surface.html) —
  library, REST, or MCP; this choice has real consequences.

## Verifying

```bash
mix deps.get
mix ci
```

`mix ci` is the real gate: format check, `compile --warnings-as-errors`, three
architectural fitness checks (namespace purity, tenancy boundary, isolation
coverage), then the default test suite. Plain `mix test` runs the suite alone.

## Provenance

The architecture this library carries — memory banks, fact-extracting retain,
hybrid recall, agentic reflect, observations, mental models — originates with
**Hindsight**, MIT-licensed work by
[Vectorize AI, Inc.](https://github.com/vectorize-io/hindsight) (paper:
[arXiv:2512.12818](https://arxiv.org/abs/2512.12818)).

Foresight holds itself accountable to the original in two ways: their copyright
notice is preserved in the [`LICENSE`](https://github.com/fosferon/foresight/blob/main/LICENSE) third-party notice, and capability
claims here are measured against their reference implementation rather than
asserted. Where this repository later diverges from the ported architecture, the
divergence is documented where it is introduced.

**Hindsight is a trademark of Vectorize AI, Inc.** Foresight is an independent
port and is not affiliated with, endorsed by, or sponsored by Vectorize AI,
Inc. References to Hindsight in this repository and its documentation serve
attribution and interoperability description only.

## Development

Local qualification workflows — the full-ML authority, contract fixture recording
against a Hindsight reference, and the heavier test lanes — live in
[`DEVELOPMENT.md`](https://github.com/fosferon/foresight/blob/main/DEVELOPMENT.md).
