defmodule Mix.Tasks.Foresight.Labeling.Kappa do
  use Mix.Task

  import Ecto.Query

  alias Foresight.Evals.Labeling.Pipeline
  alias Foresight.Evals.Labeling.RepoRuntime
  alias Foresight.Schemas.LabeledPair

  @shortdoc "Evaluate the relevance-labeling reference-vs-judge kappa gate"

  @switches [bank_id: :string, threshold: :float, reference_source: :string]
  @default_bank_id "d2-longmemeval-s"

  @impl Mix.Task
  def run(argv) do
    {parsed, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    bank_id = Keyword.get(parsed, :bank_id, @default_bank_id)
    threshold = Keyword.get(parsed, :threshold, 0.6)
    reference_source = reference_source!(Keyword.get(parsed, :reference_source))
    RepoRuntime.start!()

    rows =
      Foresight.Repo.all(
        from(label in LabeledPair,
          where: label.bank_id == ^bank_id and label.split == :calibration
        )
      )

    report =
      Pipeline.calibration_report(
        rows,
        [bank_id: bank_id, threshold: threshold] ++
          if(reference_source, do: [reference_source: reference_source], else: [])
      )

    print_report(report)

    cond do
      report.n != 40 ->
        Mix.raise("calibration join incomplete: expected 40 paired grades, got #{report.n}")

      not report.passed? ->
        Mix.raise("kappa trust gate failed; do not use the train labels for fusion tuning")

      true ->
        Mix.shell().info("kappa trust gate passed")
    end
  end

  # calibration_report/2 refuses to choose when a bank carries both :human and :agent
  # reference rows. This is how an operator resolves that without writing a script.
  defp reference_source!(nil), do: nil
  defp reference_source!("human"), do: :human
  defp reference_source!("agent"), do: :agent

  defp reference_source!(other) do
    Mix.raise("--reference-source must be human or agent, got #{inspect(other)}")
  end

  defp print_report(report) do
    kappa = if is_nil(report.kappa), do: "undefined", else: Float.to_string(report.kappa)
    reference = report.reference_source

    rows =
      report.confusion
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {counts, grade} ->
        "    #{reference} #{grade}: #{Enum.join(counts, " ")}"
      end)

    Mix.shell().info("""
    calibration report
      reference source: #{reference}#{reference_caveat(reference)}
      n: #{report.n}
      quadratic kappa: #{kappa}
      threshold: #{report.threshold}
      confusion columns (llm grades 0 1 2 3):
    #{rows}
    """)
  end

  # Printed every time so the number is never read as a stronger claim than it is.
  defp reference_caveat(:agent) do
    " (independent blind LLM raters, NOT human validation — this is " <>
      "cross-family agent-vs-judge agreement)"
  end

  defp reference_caveat(_other), do: ""
end
