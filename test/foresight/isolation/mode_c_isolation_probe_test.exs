defmodule Foresight.Isolation.ModeCIsolationProbeTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Foresight.Context
  alias Foresight.Tenancy.SchemaProvisioner
  alias Foresight.TestSupport.PostgresHarness

  # Deliberately NOT tagged :tier2. These probes are the continuous proof that
  # the cross-tenant escape stays closed; excluding them from the default lane
  # meant `mix ci` asserted the isolation guarantee without ever verifying it. They cost
  # ~6s. `mix foresight.isolation_coverage` fails the build if the tag comes back.

  defmodule Pool2Repo do
    use Ecto.Repo,
      otp_app: :foresight,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    {:ok, repo_pid} =
      start_supervised(
        {Pool2Repo,
         Keyword.merge(repo_config,
           url: harness.url,
           pool_size: 2,
           queue_target: 15_000,
           queue_interval: 15_000,
           after_connect: {Postgrex, :query!, ["RESET ROLE", []]}
         )}
      )

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Ecto.Migrator.with_repo(Pool2Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      if Process.alive?(repo_pid) do
        Supervisor.stop(repo_pid)
      end

      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)
    original_tenancy = Application.get_env(:foresight, :tenancy)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Pool2Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: Foresight.TestSupport.FakeLLM,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    Application.put_env(:foresight, :tenancy, rls_enabled: true)

    on_exit(fn ->
      restore_env(:backend, original_backend)
      restore_env(:engine, original_engine)
      restore_env(:tenancy, original_tenancy)
    end)

    :ok
  end

  test "concurrent mode_c canaries stay isolated at pool_size 2 and deleted tenants fail closed" do
    %{ctx_a: ctx_a, ctx_b: ctx_b, prefix_a: prefix_a, prefix_b: prefix_b, role_b: role_b} =
      provision_mode_c_pair!("tenant_probe_a", "tenant_probe_b")

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_a, %{
               "async" => false,
               "items" => [%{"content" => "alpha canary", "context" => "chat", "type" => "world"}]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_b, %{
               "async" => false,
               "items" => [%{"content" => "bravo canary", "context" => "chat", "type" => "world"}]
             })

    results =
      [
        %{ctx: ctx_a, query: "alpha canary", expected: "alpha canary"},
        %{ctx: ctx_b, query: "bravo canary", expected: "bravo canary"}
      ]
      |> List.duplicate(6)
      |> List.flatten()
      |> Task.async_stream(
        fn %{ctx: ctx, expected: expected} ->
          text = tenant_canary_content!(ctx)
          {ctx.tenant_id, text, expected}
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, entry} -> entry end)

    assert Enum.all?(results, fn {_tenant_id, text, expected} -> text == expected end)

    assert {:ok, %{rows: [["alpha canary"]]}} =
             SQL.query(
               Pool2Repo,
               "SELECT content FROM #{prefix_a}.memory_units WHERE bank_id = 'shared-bank'",
               []
             )

    assert {:ok, %{rows: [["bravo canary"]]}} =
             SQL.query(
               Pool2Repo,
               "SELECT content FROM #{prefix_b}.memory_units WHERE bank_id = 'shared-bank'",
               []
             )

    assert :ok = SchemaProvisioner.drop(prefix_b, repo: Pool2Repo, rls_enabled: true)
    SQL.query!(Pool2Repo, ~s|DROP ROLE IF EXISTS "#{role_b}"|, [])

    assert {:error, _reason} = tenant_canary_content(ctx_b)
    assert tenant_canary_content!(ctx_a) == "alpha canary"
  end

  test "mode_c consolidation keeps same-tag observations isolated under concurrency" do
    %{ctx_a: ctx_a, ctx_b: ctx_b, prefix_a: prefix_a, prefix_b: prefix_b} =
      provision_mode_c_pair!("tenant_consolidate_a", "tenant_consolidate_b")

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_a, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "alpha scope memory from tenant a",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_b, %{
               "async" => false,
               "items" => [
                 %{
                   "content" => "alpha scope memory from tenant b",
                   "context" => "chat",
                   "type" => "world",
                   "tags" => ["alpha"]
                 }
               ]
             })

    [ctx_a, ctx_b]
    |> Task.async_stream(
      fn ctx ->
        Foresight.consolidate(ctx, %{"tag_scopes" => [%{"tags" => ["alpha"]}]})
      end,
      max_concurrency: 2,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, result} ->
      assert {:ok, %{"success" => true}} = result
    end)

    assert {:ok, %{rows: [[content_a]]}} =
             SQL.query(
               Pool2Repo,
               "SELECT content FROM #{prefix_a}.memory_units WHERE fact_type = 'observation'",
               []
             )

    assert content_a =~ "tenant a"
    refute content_a =~ "tenant b"

    assert {:ok, %{rows: [[content_b]]}} =
             SQL.query(
               Pool2Repo,
               "SELECT content FROM #{prefix_b}.memory_units WHERE fact_type = 'observation'",
               []
             )

    assert content_b =~ "tenant b"
    refute content_b =~ "tenant a"
  end

  test "mode_c pool exhaustion pressure still returns isolated recalls" do
    %{ctx_a: ctx_a, ctx_b: ctx_b} =
      provision_mode_c_pair!("tenant_pressure_a", "tenant_pressure_b")

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_a, %{
               "async" => false,
               "items" => [
                 %{"content" => "pressure alpha", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, %{"success" => true}} =
             Foresight.retain(ctx_b, %{
               "async" => false,
               "items" => [
                 %{"content" => "pressure bravo", "context" => "chat", "type" => "world"}
               ]
             })

    [
      %{ctx: ctx_a, query: "pressure alpha", expected: "pressure alpha"},
      %{ctx: ctx_b, query: "pressure bravo", expected: "pressure bravo"}
    ]
    |> List.duplicate(10)
    |> List.flatten()
    |> Task.async_stream(
      fn %{ctx: ctx, expected: expected} ->
        text = tenant_canary_content!(ctx)
        assert text == expected
      end,
      max_concurrency: 3,
      timeout: 30_000
    )
    |> Enum.each(fn
      {:ok, true} -> :ok
      other -> flunk("unexpected pool pressure result: #{inspect(other)}")
    end)
  end

  defp provision_mode_c_pair!(slug_a, slug_b) do
    prefix_a = "#{slug_a}_schema"
    prefix_b = "#{slug_b}_schema"
    role_a = "#{slug_a}_role"
    role_b = "#{slug_b}_role"

    Enum.each([{prefix_a, role_a}, {prefix_b, role_b}], fn {prefix, role} ->
      _ = SchemaProvisioner.drop(prefix, repo: Pool2Repo, rls_enabled: true)
      SQL.query!(Pool2Repo, ~s|DROP ROLE IF EXISTS "#{role}"|, [])
      assert {:ok, _} = SchemaProvisioner.provision(prefix, repo: Pool2Repo, rls_enabled: true)
      grant_mode_c_role!(prefix, role)

      on_exit(fn ->
        _ = SchemaProvisioner.drop(prefix, repo: Pool2Repo, rls_enabled: true)
        SQL.query!(Pool2Repo, ~s|DROP ROLE IF EXISTS "#{role}"|, [])
      end)
    end)

    %{
      ctx_a: %Context{
        tenant_id: slug_a,
        mode: :mode_c,
        bank: "shared-bank",
        prefix: prefix_a,
        role_name: role_a
      },
      ctx_b: %Context{
        tenant_id: slug_b,
        mode: :mode_c,
        bank: "shared-bank",
        prefix: prefix_b,
        role_name: role_b
      },
      prefix_a: prefix_a,
      prefix_b: prefix_b,
      role_a: role_a,
      role_b: role_b
    }
  end

  defp grant_mode_c_role!(prefix, role_name) do
    SQL.query!(Pool2Repo, ~s|CREATE ROLE "#{role_name}" NOINHERIT|, [])
    SQL.query!(Pool2Repo, ~s|GRANT USAGE ON SCHEMA "#{prefix}" TO "#{role_name}"|, [])

    SQL.query!(
      Pool2Repo,
      ~s|GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      []
    )

    SQL.query!(
      Pool2Repo,
      ~s|GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "#{prefix}" TO "#{role_name}"|,
      []
    )
  end

  defp tenant_canary_content!(ctx) do
    case tenant_canary_content(ctx) do
      {:ok, content} -> content
      {:error, reason} -> raise "tenant canary read failed: #{inspect(reason)}"
    end
  end

  defp tenant_canary_content(ctx) do
    try do
      Foresight.Tenancy.with_tenant_role(
        ctx,
        fn ->
          case SQL.query(
                 Pool2Repo,
                 "SELECT content FROM #{ctx.prefix}.memory_units WHERE bank_id = 'shared-bank' ORDER BY inserted_at DESC LIMIT 1",
                 []
               ) do
            {:ok, %{rows: [[content]]}} -> {:ok, content}
            {:ok, %{rows: []}} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end
        end,
        repo: Pool2Repo
      )
    rescue
      error in [Postgrex.Error, DBConnection.ConnectionError] ->
        {:error, error}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:foresight, key)
  defp restore_env(key, value), do: Application.put_env(:foresight, key, value)
end
