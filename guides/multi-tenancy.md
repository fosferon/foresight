# Multi-tenancy

Three isolation models, in ascending order of both strength and setup cost.
Choose deliberately: the difference between them is where the guarantee lives.

## Mode A — application-scoped

```elixir
%Foresight.Context{tenant_id: "default", mode: :mode_a, bank: "notes"}
```

One schema. Every query is scoped by bank in application code. Fine for a single
tenant, or where "tenants" are your own subsystems and a bug leaking between them
is embarrassing rather than serious.

The guarantee lives entirely in Foresight's query construction. If that is not
enough for your data, it is not enough.

## Mode B — row-level

Rows carry a tenant column and queries are filtered on it. Still application
code, but the boundary is explicit and auditable in the data.

## Mode C — schema-per-tenant with enforced RLS

```elixir
%Foresight.Context{tenant_id: "acme", mode: :mode_c, bank: "notes"}
```

Each tenant gets its own PostgreSQL schema. Connections `SET ROLE` to a
tenant-specific role for the duration of the work and `RESET ROLE` afterwards,
re-entrantly. Tables carry `ROW LEVEL SECURITY` **and** `FORCE ROW LEVEL
SECURITY`.

Here the guarantee lives in the database. A bug in Foresight's query building
does not breach it, because the database refuses to return rows the connection's
role cannot see.

### Provisioning from an in-BEAM consumer

Use the public role-neutral provisioning seam:

```elixir
{:ok, %{tenant_id: tenant_id, prefix: prefix, migrated_versions: versions}} =
  Foresight.Tenancy.provision_mode_c_schema(
    MyApp.Repo,
    "acme",
    "tenant_acme",
    rls_enabled: true
  )
```

The call first installs or upgrades Foresight's shared control plane, then
creates or rechecks the tenant schema from packaged tenant migrations. It is
idempotent. `:rls_enabled` is mandatory and must be `true` or `false`; there is
no application-environment fallback at this boundary.

Historical public-schema data repairs are classified separately and are not
replayed into newly provisioned tenant schemas.
The `public` schema is reserved for the host application and cannot be used as
a Mode C tenant prefix.

This seam is deliberately authority-neutral: it starts no tenant runtime,
creates no PostgreSQL role, and writes no tenant API key. A host that owns role
or credential lifecycle must do that itself. Foresight's HTTP tenant lifecycle
remains available for deployments that intentionally want those side effects.

The same explicit `rls_enabled:` option may be passed to public memory
operations. A per-call `false` overrides an application default of `true`,
including the parallel recall strategies and nested reflect calls. Async
storage, migration, and webhook jobs persist only this boolean and restore it in
the worker; no Repo credentials or other caller options are serialized.

### The part that is easy to get wrong

**RLS does not apply to superusers, and it does not apply to a table's owner.**
If your application connects as `postgres`, Mode C is decorative — you have
configured a guarantee that is not in force, and every test will still pass.

The application role must be non-superuser and must not own the tenant tables.
Getting there requires five distinct things, documented in
[the Mode C least-privilege runbook](mode-c-least-privilege.md) in the order they actually fail, with the
real error strings. Setting it up is genuinely fiddly and the runbook exists
because we did it wrong five times first.

### Verifying rather than assuming

```bash
VICTIM_API_KEY=... elixir scripts/mode_c_isolation_proof.exs
```

Five forged-header cross-tenant attacks against a running instance over real
HTTP. It checks the attacker's responses for the victim's canary string rather
than trusting status codes — a 200 with empty results and a 403 both look like
"blocked" from the outside, but only one of them means the data stayed put.

- **exit 0** — attacks blocked, and the script confirmed it could have detected a
  breach
- **exit 2** — INCONCLUSIVE. Not a pass. The self-check did not confirm, so the
  run proves nothing.

Last verified run: `rolsuper = false`, RLS forced, **5/5 blocked**.

A continuous check runs in `mix ci` too: `mix foresight.isolation_coverage` fails
the build if the isolation tests are tagged out of the default lane or the suite
is empty. A silently-skipped isolation probe reads as coverage while providing
none, which is worse than having no probe at all.

## Choosing

| | Mode A | Mode B | Mode C |
| --- | --- | --- | --- |
| Guarantee enforced by | app code | app code | **PostgreSQL** |
| Setup cost | none | low | real |
| Survives a Foresight bug | no | no | **yes** |
| Suitable for others' personal data | no | depends | **yes** |
