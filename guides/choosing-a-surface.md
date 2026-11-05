# Choosing a surface

Foresight speaks three ways. They are not equivalent, and the choice is easier to
make now than to unmake later.

## 1. As a library — the default answer

```elixir
{:foresight, "~> 0.3", hex: :foresight_memory}
```

Your application calls `Foresight.recall/3` directly. No serialization, no HTTP,
no session lifecycle, no transport errors to distinguish from real ones. Errors
arrive as `Foresight.Error` structs you can pattern-match:

```elixir
case Foresight.reflect(ctx, %{"query" => q}) do
  {:ok, answer} -> answer
  {:error, %Foresight.Error{reason: :unavailable}} -> :fallback
end
```

Everything below is a wrapper over this. If your application is Elixir and
memory lives in the same release, there is no argument for adding a network hop
to talk to yourself.

## 2. REST — when you need a boundary

67 routes under `/v1/:tenant/banks/...`: banks, memories, recall, reflect,
observations, mental models, operations, directives, import/export.

```elixir
config :foresight,
  http: [enabled: true, port: 4000],
  auth: [service_api_key: System.fetch_env!("FORESIGHT_API_KEY")]
```

Choose it when the caller is not Elixir, when memory must scale separately, or
when you want a hard operational boundary. This is the surface the benchmark
harnesses drive, so it is well travelled.

HTTP refuses to start without either a credential or an explicit
`auth: [allow_anonymous: true]`. That is on purpose: an unauthenticated memory
service is a data-exfiltration endpoint, and the failure should happen at boot on
your laptop rather than in production.

## 3. MCP — for tools that speak it

11 tools over streamable HTTP, for Claude Desktop, IDE agents, and anything else
in the MCP ecosystem.

```elixir
config :foresight, http: [enabled: true], mcp: [enabled: true]
```

It works, and every defect found in the last integration spike is fixed. Two
structural properties survive those fixes, and you should know them before
choosing it rather than after:

**One process owns every session.** A single Hermes.Server.Base GenServer
holds all live MCP sessions. The reachable crash paths are closed and tested, but
a raise originating outside the tool path would affect every connected client at
once. That is a property of the architecture, not a bug awaiting a fix.

**Ported clients may need `lenient_session: true`.** Clients written against
Python Hindsight post a bare `tools/call` with no MCP handshake. Foresight's
transport enforces the lifecycle and answers `Server not initialized`. The flag
drives the handshake on their behalf:

```elixir
config :foresight, mcp: [enabled: true, lenient_session: true]
```

It is **off by default** and logs each fabricated session. Sessions it fabricates
are torn down at the end of the request that created them, so this no longer
accumulates processes under load — but a client that echoes back the
`Mcp-Session-Id` header still pays one round trip instead of three.

Argument names from Python Hindsight are accepted: `async_processing` is an alias
for `async`, an explicit `async` wins over the alias, and any undeclared argument
is *named in the log* rather than silently dropped.

## Choosing

| | library | REST | MCP |
| --- | --- | --- | --- |
| Caller is Elixir, same release | **yes** | no | no |
| Caller is another language/service | no | **yes** | no |
| Caller is an MCP client | no | no | **yes** |
| Latency floor | function call | HTTP | HTTP + JSON-RPC |
| Blast radius of one bad call | that call | that request | see above |

Nothing stops you enabling several at once — the same engine serves all three.
