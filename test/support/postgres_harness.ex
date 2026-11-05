defmodule Foresight.TestSupport.PostgresHarness do
  @moduledoc false

  @prefix "foresight-postgres-"

  # Remove instances left behind by crashed runs. Only instances whose postmaster is
  # gone are touched: this used to stop and delete EVERY harness instance on the
  # machine, so two test runs (two worktrees, or a tier2 lane next to an eval) tore
  # down each other's database mid-run.
  def cleanup_stale! do
    pattern = Path.join(System.tmp_dir!(), "#{@prefix}*")

    for path <- Path.wildcard(pattern), not postmaster_alive?(Path.join(path, "data")) do
      data_dir = Path.join(path, "data")

      # Best-effort stop with a short timeout; ignore errors from dead instances.
      _ =
        System.cmd("pg_ctl", ["-D", data_dir, "-m", "immediate", "-W", "stop"],
          stderr_to_stdout: true
        )

      File.rm_rf(path)
    end

    :ok
  end

  @doc false
  def postmaster_alive?(data_dir) do
    with {:ok, contents} <- File.read(Path.join(data_dir, "postmaster.pid")),
         [pid_line | _] <- String.split(contents, "\n"),
         {pid, ""} <- Integer.parse(String.trim(pid_line)) do
      match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
    else
      _ -> false
    end
  end

  def start!(opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Path.join(System.tmp_dir!(), "#{@prefix}#{System.unique_integer([:positive])}")
      end)

    data_dir = Path.join(root, "data")
    socket_dir = Path.join(root, "socket")
    log_path = Path.join(root, "postgres.log")
    port = Keyword.get_lazy(opts, :port, &free_port!/0)
    database = Keyword.get(opts, :database, "foresight_test")

    File.rm_rf(root)
    File.mkdir_p!(socket_dir)

    run!("initdb", [
      "-D",
      data_dir,
      "-A",
      "trust",
      "-U",
      "postgres",
      "--encoding",
      "UTF8",
      "--locale=C"
    ])

    run!("pg_ctl", [
      "-D",
      data_dir,
      "-l",
      log_path,
      "-o",
      "-p #{port} -k #{socket_dir}",
      "-w",
      "start"
    ])

    run!("createdb", [
      "-h",
      socket_dir,
      "-p",
      Integer.to_string(port),
      "-U",
      "postgres",
      database
    ])

    %{
      root: root,
      data_dir: data_dir,
      socket_dir: socket_dir,
      log_path: log_path,
      port: port,
      database: database,
      url: "postgresql://postgres@127.0.0.1:#{port}/#{database}"
    }
  end

  def stop!(%{data_dir: data_dir, root: root}) do
    _ =
      System.cmd("pg_ctl", ["-D", data_dir, "-m", "immediate", "-w", "stop"],
        stderr_to_stdout: true
      )

    File.rm_rf(root)
    :ok
  end

  defp run!(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        raise """
        #{command} #{Enum.join(args, " ")} failed with exit status #{status}

        #{output}
        """
    end
  end

  defp free_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
