defmodule Mix.Tasks.Foresight.Ingest.Scrivener do
  use Mix.Task

  @shortdoc "Ingests a Scrivener .scriv bundle into a Foresight bank"

  @moduledoc false

  @impl true
  def run(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [bank: :string, tenant: :string, mode: :string, async: :boolean, tag: :keep]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    [scriv_path] = paths_or_raise!(paths)
    bank_id = Keyword.get(opts, :bank) || Mix.raise("--bank is required")

    Mix.Task.run("app.start")

    ingest_opts = [
      tenant_id: Keyword.get(opts, :tenant, "default"),
      mode: Keyword.get(opts, :mode, "mode_a"),
      async: Keyword.get(opts, :async, false),
      tags: Keyword.get_values(opts, :tag)
    ]

    case Foresight.Ingestion.Scrivener.ingest(scriv_path, bank_id, ingest_opts) do
      {:ok, result} ->
        Mix.shell().info(
          "ingested #{scriv_path} into #{bank_id}: #{inspect(Map.take(result, ["items_count", "operation_id", "operation_ids"]))}"
        )

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end

  defp paths_or_raise!([path]), do: [path]

  defp paths_or_raise!(_paths) do
    Mix.raise("usage: mix foresight.ingest.scrivener <scriv_path> --bank <id>")
  end
end
