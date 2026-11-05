# Mode C least-privilege runbook

Moving Foresight off a superuser database login, and proving tenant isolation on a running
instance.

Every command below was executed end to end against a real instance on 2026-08-13.
The failure modes documented are ones that actually occurred, in the order they occurred —
not anticipated ones.

## Why this matters

Application code keeps each tenant to its own rows, and `FORCE ROW LEVEL SECURITY` is
applied to every tenant table at provision time. But **a superuser bypasses RLS entirely, and
`FORCE` does not change that.** While the application logs in as `postgres`, the isolation
guarantee rests on application code alone; the database is not enforcing anything. Switching
the login role is what turns RLS from decoration into a second, independent barrier.

## The five requirements

A non-superuser application login needs all of these. Missing any one produces a specific,
recognisable failure, listed with each.

### 1. The role itself

```sql
CREATE ROLE foresight_app LOGIN PASSWORD '<secret>' NOSUPERUSER CREATEROLE;
GRANT CONNECT ON DATABASE <db> TO foresight_app;
GRANT CREATE  ON DATABASE <db> TO foresight_app;
```

`CREATEROLE` is required: provisioning a tenant executes `CREATE ROLE "<tenant>_role"`.
`CREATE ON DATABASE` is required for `CREATE SCHEMA` at provision time.

> Missing `CREATE ON DATABASE` →
> `[Tenancy.Reconciler] reconcile failed: permission denied for database <db>`

### 2. Schema ownership

```sql
ALTER SCHEMA public             OWNER TO foresight_app;
ALTER SCHEMA foresight_template OWNER TO foresight_app;
-- and every existing tenant schema
ALTER SCHEMA tenant_<x>         OWNER TO foresight_app;
```

`foresight_template` is the schema `SchemaCloner` clones from; the app must read it.

> Missing → `permission denied for schema foresight_template`

Note `REASSIGN OWNED BY postgres TO foresight_app` does **not** work — Postgres refuses with
*"cannot reassign ownership of objects owned by role postgres because they are required by
the database system"*. Transfer schema by schema.

### 3. Table and sequence ownership — not merely privileges

```sql
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname, tablename FROM pg_tables
           WHERE schemaname LIKE 'tenant_%'
              OR schemaname IN ('foresight_template','public')
  LOOP
    EXECUTE format('ALTER TABLE %I.%I OWNER TO foresight_app', r.schemaname, r.tablename);
  END LOOP;

  FOR r IN SELECT sequence_schema, sequence_name FROM information_schema.sequences
           WHERE sequence_schema LIKE 'tenant_%'
              OR sequence_schema IN ('foresight_template','public')
  LOOP
    EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO foresight_app',
                   r.sequence_schema, r.sequence_name);
  END LOOP;
END $$;
```

This is the step people skip. `GRANT ALL` is not enough: provisioning runs
`ALTER TABLE ... ENABLE / FORCE ROW LEVEL SECURITY`, and **`ALTER TABLE` requires ownership**.

> Missing → `must be owner of table audit_log`

This is also why the posture is coherent rather than contradictory: the app owns the tables,
and `FORCE ROW LEVEL SECURITY` is precisely the flag that stops an owner from bypassing RLS.
Owner + FORCE is the intended combination.

### 4. Re-grant every pre-existing tenant role — the migration trap

```sql
GRANT "tenant_<x>_role" TO foresight_app;   -- for EVERY tenant provisioned before the switch
```

Provisioning runs `GRANT "<tenant>_role" TO CURRENT_USER`. `CURRENT_USER` is the login role
**at the time of provisioning**. Tenants created while the app ran as `postgres` granted
their role to `postgres`, so a new login cannot `SET ROLE` into them. Newly provisioned
tenants are fine automatically; existing ones must be re-granted.

> Missing → health reports
> `permission denied to set role "tenant_<x>_role"`

Enumerate them:

```sql
SELECT DISTINCT format('GRANT %I TO foresight_app;', k.role_name)
  FROM public.tenant_keys k
  JOIN public.tenant_lifecycles l ON l.tenant_id = k.slug
 WHERE l.status = 'provisioned'
   AND k.role_name IS NOT NULL;
```

`DISTINCT` matters because a tenant may hold several API keys, all naming the same role;
the lifecycle join keeps dropped tenants out of the list.

### 5. Default privileges for future objects

```sql
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO foresight_app;
```

## Verification — do not skip

**a. Confirm the login is genuinely unprivileged.**

```sql
SELECT current_user,
       (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) AS is_superuser;
-- expect: foresight_app | f
```

If `is_superuser` is `t`, nothing below means anything.

**b. Confirm RLS is enabled *and* forced on tenant tables.**

```sql
SELECT c.relname, c.relrowsecurity AS rls, c.relforcerowsecurity AS forced
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'tenant_<x>' AND c.relkind = 'r';
-- expect rls=t forced=t on every table (schema_migrations is exempt)
```

**c. Confirm the posture monitor is healthy.**

```
curl -s http://<host>:<port>/health
```

Expect `"status":"healthy"` with `"failures":[]`. The monitor probes a real `SET ROLE` /
`RESET ROLE` round trip per tenant, so an unhealthy result here names the exact tenant and
the exact privilege that is missing. Read it — it is the fastest diagnostic in the system.

**d. Run the live isolation proof.**

```
FORESIGHT_URL=http://<host>:<port> \
VICTIM_TENANT=<tenant> VICTIM_PREFIX=<prefix> VICTIM_ROLE=<role> \
VICTIM_API_KEY=<the tenant's real key> \
elixir scripts/mode_c_isolation_proof.exs
```

Always pass `VICTIM_API_KEY`. Without it the script exits `2` (INCONCLUSIVE) rather than
`0`, because a sweep of blocked attacks proves nothing unless the canary was demonstrably
readable in the first place — otherwise a misconfigured target, an empty tenant, or a typo'd
bank name all produce a clean-looking pass.

Expected: `5/5 attacks blocked` and `PASS`.

## Verified result

Executed 2026-08-13 against a live instance:

```
foresight_app super=false
documents      rls=true force=true
labeled_pairs  rls=true force=true
audit_log      rls=true force=true
health: {"status":"healthy","tenancy_posture":{"failures":[],...}}

  BLOCKED  bare bearer + forged tenant/prefix/role             status=401
  BLOCKED  empty bearer + forged headers                       status=401
  BLOCKED  no bearer at all + forged headers                   status=401
  BLOCKED  forged prefix only (no tenant id)                   status=401
  BLOCKED  unknown tenant id with a plausible key shape        status=401
  (self-check OK — the canary is present and the detector fires)

5/5 attacks blocked. PASS
```

## Code change this required

`Foresight.Tenancy.PostureMonitor` compared the post-`RESET ROLE` role against the literal
string `"postgres"`. It now compares against `session_user`. The hardcoded literal meant the
monitor could only ever report healthy when the app logged in as `postgres` — that is, it
structurally forbade the very posture this runbook establishes, reporting
`role reset drift detected after probe: "foresight_app"` on a correctly configured system.
