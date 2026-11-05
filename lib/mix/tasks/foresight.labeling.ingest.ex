defmodule Mix.Tasks.Foresight.Labeling.Ingest do
  use Mix.Task

  alias Foresight.Evals.Labeling.GoldIngest
  alias Foresight.Evals.Labeling.LabelStore
  alias Foresight.Evals.Labeling.RepoRuntime

  @shortdoc "Ingest a fully graded relevance reference artifact (--source human|agent)"

  @switches [
    input: :string,
    expected_pairs: :integer,
    expected_calibration: :integer,
    source: :string
  ]
  @defaults [
    input: "tmp/labeling/judge-prefilled.json",
    expected_pairs: 150,
    expected_calibration: 40,
    # Reference grades to date are agent-produced, not human. The default is
    # deliberately explicit rather than assumed.
    source: "agent"
  ]

  @impl Mix.Task
  def run(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    opts = Keyword.merge(@defaults, parsed)
    path = opts[:input]

    unless opts[:expected_pairs] > opts[:expected_calibration] and
             opts[:expected_calibration] > 0 do
      Mix.raise("--expected-pairs must exceed positive --expected-calibration")
    end

    artifact = path |> File.read!() |> Jason.decode!()
    result = GoldIngest.parse(artifact, source: reference_source!(opts[:source]))

    if result.errors != [] or result.skipped != 0 do
      Mix.raise(
        "reference artifact is incomplete: #{result.skipped} blank grades, " <>
          "#{length(result.errors)} invalid rows"
      )
    end

    calibration = Enum.count(result.labels, &(&1.split == :calibration))
    test = Enum.count(result.labels, &(&1.split == :test))

    expected_test = opts[:expected_pairs] - opts[:expected_calibration]

    unless length(result.labels) == opts[:expected_pairs] and
             calibration == opts[:expected_calibration] and test == expected_test do
      Mix.raise(
        "expected #{opts[:expected_pairs]} reference labels split " <>
          "#{opts[:expected_calibration]}/#{expected_test}, got " <>
          "#{length(result.labels)} split #{calibration}/#{test}"
      )
    end

    RepoRuntime.start!()
    stored = LabelStore.write_all(result.labels)

    if stored.errors != [] do
      Mix.raise("failed to persist #{length(stored.errors)} reference labels")
    end

    Mix.shell().info(
      "persisted #{stored.written} #{opts[:source]} labels for #{artifact["bank_id"]} " <>
        "(calibration/test #{calibration}/#{test})"
    )
  end

  defp reference_source!("human"), do: :human
  defp reference_source!("agent"), do: :agent

  defp reference_source!(other) do
    Mix.raise("--source must be human or agent, got #{inspect(other)}")
  end
end
