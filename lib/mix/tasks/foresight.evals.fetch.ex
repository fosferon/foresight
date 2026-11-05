defmodule Mix.Tasks.Foresight.Evals.Fetch do
  @shortdoc "Download a license-clean eval dataset split into priv/evals/data/ (gitignored)"
  @moduledoc """
  Fetch an evaluation dataset split on demand. Nothing is redistributed in the repo — the
  data lands in `priv/evals/data/`, which is gitignored.

      mix foresight.evals.fetch longmemeval_oracle   # ~15 MB, evidence-only (reflect dev)
      mix foresight.evals.fetch longmemeval_s        # ~277 MB, full haystack (retrieval@scale)

  LongMemEval is MIT-licensed (Wu et al., ICLR 2025):
  https://github.com/xiaowu0162/LongMemEval
  """
  use Mix.Task

  @base "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main"

  @splits %{
    "longmemeval_oracle" => "longmemeval_oracle.json",
    "longmemeval_s" => "longmemeval_s_cleaned.json",
    "longmemeval_m" => "longmemeval_m_cleaned.json"
  }

  @impl Mix.Task
  def run(argv) do
    split =
      case argv do
        [split | _] -> split
        [] -> Mix.raise("usage: mix foresight.evals.fetch <#{Enum.join(Map.keys(@splits), "|")}>")
      end

    remote = Map.get(@splits, split) || Mix.raise("unknown split #{split}")
    dir = Path.join(["priv", "evals", "data"])
    File.mkdir_p!(dir)
    dest = Path.join(dir, "#{split}.json")

    if File.exists?(dest) do
      Mix.shell().info("already present: #{dest} (#{human_size(dest)})")
    else
      url = "#{@base}/#{remote}"
      Mix.shell().info("fetching #{url}\n  → #{dest}")
      {_out, 0} = System.cmd("curl", ["-fSL", url, "-o", dest], into: IO.stream(:stdio, :line))
      Mix.shell().info("done: #{dest} (#{human_size(dest)})")
    end
  end

  defp human_size(path) do
    bytes = File.stat!(path).size
    "#{Float.round(bytes / 1_000_000, 1)} MB"
  end
end
