defmodule Foresight.Repo.Migrations.ReclassifyAgentGradedLabeledPairs do
  @moduledoc """
  The labeled-pair reference grades were never human.

  Both gold artifacts (the generated gold set and its reviewed copy)
  contain 150 rows each with `grade: null` — no person ever graded a pair. The rows
  stored as `source: 'human'` are independent-agent grades: dual blind raters
  (claude-fable-5) plus lead adjudication, verified identical to the shipped artifacts on
  40/40 calibration and 110/110 test in both lanes.

  They were stored as 'human' only because the enum offered nowhere else to put them,
  which made the kappa gate read as human validation. It is cross-family agent-vs-judge
  agreement — real evidence, different evidence.

  Scoped to the two banks whose provenance was verified rather than blanket-updating
  every 'human' row, so that a genuinely human-graded row elsewhere (now or later) is
  never silently reclassified.
  """
  use Ecto.Migration

  # public-guard: allow (bank ids of existing rows; up/0 and down/0 match on them)
  @banks ["d2-longmemeval-s-gc2727-final", "d2-professional-lane"]
  @provenance "claude-fable-5@gc-3802-blind-dual-rater" # public-guard: allow (stamp in existing rows; down/0 matches it)

  def up do
    for bank <- @banks do
      execute("""
      UPDATE labeled_pairs
         SET source = 'agent',
             judge_model = '#{@provenance}'
       WHERE bank_id = '#{bank}'
         AND source = 'human'
      """)
    end
  end

  # Reverses exactly the rows `up` touched and no others. Matching on the provenance stamp
  # is what makes that precise: a genuinely agent-graded row written later (the ingest task
  # now defaults to --source agent) carries a different judge_model, so a rollback leaves
  # it alone instead of silently relabelling it as human.
  def down do
    for bank <- @banks do
      execute("""
      UPDATE labeled_pairs
         SET source = 'human',
             judge_model = NULL
       WHERE bank_id = '#{bank}'
         AND source = 'agent'
         AND judge_model = '#{@provenance}'
      """)
    end
  end
end
