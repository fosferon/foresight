defmodule Foresight.MigrationScratchTest do
  use ExUnit.Case, async: true

  alias Foresight.Migrations.Scratch

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "foresight-scratch-test-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "removes a partial directory when a migration link fails", %{root: root} do
    migration = %{filename: "migration.exs", path: "/nonexistent/migration.exs"}

    assert {:error, :eexist} = Scratch.materialize([migration, migration], root)
    assert Path.wildcard(Path.join(root, "*")) == []
  end

  test "allocates distinct directories concurrently without touching stale paths", %{root: root} do
    stale = Path.join(root, "foresight-control-migrations-1")
    File.mkdir!(stale)
    File.write!(Path.join(stale, "sentinel"), "unchanged")

    migration = %{filename: "migration.exs", path: "/nonexistent/migration.exs"}

    paths =
      1..16
      |> Task.async_stream(fn _ -> Scratch.materialize([migration], root) end,
        max_concurrency: 16,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, {:ok, path}} -> path end)

    assert length(Enum.uniq(paths)) == 16
    assert Enum.all?(paths, &File.dir?/1)

    assert Enum.all?(paths, fn path ->
             File.read_link(Path.join(path, migration.filename)) == {:ok, migration.path}
           end)

    assert File.read!(Path.join(stale, "sentinel")) == "unchanged"
  end

  test "fresh concurrent BEAMs sharing TMPDIR do not reuse a directory", %{root: root} do
    stale = Path.join(root, "foresight-control-migrations-1")
    File.mkdir!(stale)
    File.write!(Path.join(stale, "sentinel"), "unchanged")

    beam_path = Scratch |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    migration = %{filename: "migration.exs", path: "/nonexistent/migration.exs"}
    case Foresight.Migrations.Scratch.materialize([migration], System.fetch_env!("TMPDIR")) do
      {:ok, path} -> IO.puts(path)
      {:error, reason} -> IO.puts(:stderr, inspect(reason)); System.halt(1)
    end
    """

    paths =
      1..2
      |> Task.async_stream(
        fn _ ->
          System.cmd(System.find_executable("elixir"), ["-pa", beam_path, "-e", script],
            env: [{"TMPDIR", root}],
            stderr_to_stdout: true
          )
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {output, 0}} -> String.trim(output) end)

    assert length(Enum.uniq(paths)) == 2

    for path <- paths do
      assert Path.dirname(path) == root

      assert File.read_link(Path.join(path, "migration.exs")) ==
               {:ok, "/nonexistent/migration.exs"}
    end

    assert File.read!(Path.join(stale, "sentinel")) == "unchanged"
  end
end
