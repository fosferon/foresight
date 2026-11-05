defmodule Foresight.Tenancy.WithTenantRoleTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Tenancy
  alias Foresight.TestSupport.PostgresHarness

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config,
        url: harness.url,
        pool_size: 10,
        # Use the REAL production after_connect hook (supervisor.ex wires this),
        # so tests exercise reset_connection/1 faithfully — including the HNSW
        # ef_search=200 parity setting.
        after_connect: {Foresight.Tenancy, :reset_connection, []}
      )
    )

    start_supervised!(Foresight.Repo)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    SQL.query!(Foresight.Repo, ~s|DROP SCHEMA IF EXISTS "tenant_role_a" CASCADE|, [])
    SQL.query!(Foresight.Repo, ~s|DROP SCHEMA IF EXISTS "tenant_role_b" CASCADE|, [])
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_role_a_reader"|, [])
    SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_role_b_reader"|, [])

    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "tenant_role_a_reader" NOINHERIT|, [])
    SQL.query!(Foresight.Repo, ~s|CREATE ROLE "tenant_role_b_reader" NOINHERIT|, [])

    SQL.query!(Foresight.Repo, ~s|CREATE SCHEMA "tenant_role_a"|, [])
    SQL.query!(Foresight.Repo, ~s|CREATE SCHEMA "tenant_role_b"|, [])
    SQL.query!(Foresight.Repo, ~s|CREATE TABLE "tenant_role_a"."notes" (value text)|, [])
    SQL.query!(Foresight.Repo, ~s|CREATE TABLE "tenant_role_b"."notes" (value text)|, [])

    SQL.query!(
      Foresight.Repo,
      ~s|INSERT INTO "tenant_role_a"."notes" (value) VALUES ('alpha')|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|INSERT INTO "tenant_role_b"."notes" (value) VALUES ('beta')|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE ON SCHEMA "tenant_role_a" TO "tenant_role_a_reader"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT ON "tenant_role_a"."notes" TO "tenant_role_a_reader"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT USAGE ON SCHEMA "tenant_role_b" TO "tenant_role_b_reader"|,
      []
    )

    SQL.query!(
      Foresight.Repo,
      ~s|GRANT SELECT ON "tenant_role_b"."notes" TO "tenant_role_b_reader"|,
      []
    )

    on_exit(fn ->
      SQL.query!(Foresight.Repo, ~s|DROP SCHEMA IF EXISTS "tenant_role_a" CASCADE|, [])
      SQL.query!(Foresight.Repo, ~s|DROP SCHEMA IF EXISTS "tenant_role_b" CASCADE|, [])
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_role_a_reader"|, [])
      SQL.query!(Foresight.Repo, ~s|DROP ROLE IF EXISTS "tenant_role_b_reader"|, [])
    end)

    :ok
  end

  test "runs mode_c work under a checked-out tenant role without pinning the callback in a transaction" do
    ctx = %Context{
      tenant_id: "tenant-a",
      mode: :mode_c,
      bank: "default",
      role_name: "tenant_role_a_reader",
      prefix: "tenant_role_a"
    }

    assert %{
             current_role: "tenant_role_a_reader",
             current_prefix: "tenant_role_a",
             in_transaction?: false,
             note_rows: [["alpha"]]
           } =
             Tenancy.with_tenant_role(
               ctx,
               fn ->
                 %{
                   current_role:
                     SQL.query!(Foresight.Repo, "SELECT current_role", []).rows
                     |> List.first()
                     |> hd(),
                   current_prefix:
                     SQL.query!(
                       Foresight.Repo,
                       "SELECT current_setting('foresight.tenant_prefix', true)",
                       []
                     ).rows
                     |> List.first()
                     |> hd(),
                   in_transaction?: Foresight.Repo.in_transaction?(),
                   note_rows:
                     SQL.query!(Foresight.Repo, ~s|SELECT value FROM "tenant_role_a"."notes"|, []).rows
                 }
               end,
               repo: Foresight.Repo,
               rls_enabled: true
             )

    assert %{rows: [["postgres"]]} = SQL.query!(Foresight.Repo, "SELECT current_role", [])

    # Empty string (not nil): the production after_connect hook (reset_connection)
    # RESETs the custom GUC on connect, so its value is "" — the "no active prefix"
    # state — rather than never-set. Either way: no tenant prefix leaks.
    assert %{rows: [[""]]} =
             SQL.query!(
               Foresight.Repo,
               "SELECT current_setting('foresight.tenant_prefix', true)",
               []
             )
  end

  # A cross-tenant escape that once had no test: with_tenant_role/3 was not
  # re-entrant: a nested scope's `after` block ran RESET ROLE while the OUTER scope still
  # believed it was tethered, so work after the inner call returned executed as the login
  # role with RLS bypassed. The confirmed instance was reflect_observations/3 wrapping,
  # calling list_memories/3 which wrapped again, and then running
  # bank_consolidation_state unscoped.
  test "a nested scope does not un-tether the outer scope on return" do
    ctx = %Context{
      tenant_id: "tenant-a",
      mode: :mode_c,
      bank: "default",
      role_name: "tenant_role_a_reader",
      prefix: "tenant_role_a"
    }

    role = fn ->
      SQL.query!(Foresight.Repo, "SELECT current_role", []).rows |> List.first() |> hd()
    end

    prefix = fn ->
      SQL.query!(Foresight.Repo, "SELECT current_setting('foresight.tenant_prefix', true)", []).rows
      |> List.first()
      |> hd()
    end

    result =
      Tenancy.with_tenant_role(
        ctx,
        fn ->
          before_nested = {role.(), prefix.()}

          inner =
            Tenancy.with_tenant_role(ctx, fn -> {role.(), prefix.()} end,
              repo: Foresight.Repo,
              rls_enabled: true
            )

          # The assertion that matters: still scoped AFTER the inner scope returned.
          %{before: before_nested, inner: inner, after_nested: {role.(), prefix.()}}
        end,
        repo: Foresight.Repo,
        rls_enabled: true
      )

    assert result.before == {"tenant_role_a_reader", "tenant_role_a"}
    assert result.inner == {"tenant_role_a_reader", "tenant_role_a"}
    assert result.after_nested == {"tenant_role_a_reader", "tenant_role_a"}

    # And the outermost exit still resets fully — re-entrancy must not leak the scope out.
    assert %{rows: [["postgres"]]} = SQL.query!(Foresight.Repo, "SELECT current_role", [])

    assert %{rows: [[""]]} =
             SQL.query!(
               Foresight.Repo,
               "SELECT current_setting('foresight.tenant_prefix', true)",
               []
             )
  end

  test "reset_connection sets hnsw.ef_search=200 on every pooled connection" do
    # Hindsight runs `SET hnsw.ef_search = 200` per connection (memory_engine.py:1903)
    # to lift HNSW recall quality on the per-fact_type semantic queries. Foresight set
    # nothing → pgvector default 40. The parity fix lives in the after_connect hook, so
    # any pooled connection must report 200.
    assert %{rows: [["200"]]} = SQL.query!(Foresight.Repo, "SHOW hnsw.ef_search", [])
  end

  test "denies cross-tenant schema reads under the tenant role" do
    ctx = %Context{
      tenant_id: "tenant-a",
      mode: :mode_c,
      bank: "default",
      role_name: "tenant_role_a_reader",
      prefix: "tenant_role_a"
    }

    assert_raise Postgrex.Error, fn ->
      Tenancy.with_tenant_role(ctx, fn ->
        SQL.query!(Foresight.Repo, ~s|SELECT value FROM "tenant_role_b"."notes"|, [])
      end)
    end
  end
end
