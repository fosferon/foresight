defmodule Foresight.Schemas.LabeledPair do
  @moduledoc """
  Graded relevance label for a (query, candidate memory) pair — the
  training/eval substrate for learned per-bank fusion weights.

  Each row is *one source's* grade for one pair. Candidates are keyed on `memory_ref`,
  the stable corpus id (`metadata["eval_id"]`), NOT the ephemeral `memory_units.id` UUID,
  so a human-graded gold set survives corpus reloads instead of being re-labelled each run.

  Cohen's weighted kappa is computed by joining a REFERENCE source (`:human` or `:agent`)
  against `source: :llm` on `{query_ref, memory_ref}` where `split == :calibration`. The
  `:test` split is the held-out reference set the judge never sees; `:train` is the bulk
  LLM-labelled set the fusion tuner ascends against.

  Currently, the shipped reference set for both labeling lanes is `:agent`, not `:human` —
  no person has graded a pair yet. `Pipeline.calibration_report/2` always reports which
  reference source it scored against, and refuses to pick silently when both are present.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # :agent is a distinct provenance from :human on purpose. The earlier reference
  # grades were produced by independent blind LLM raters, not people, and storing them as
  # :human made the kappa gate read as human validation when it is cross-family
  # agent-vs-judge agreement. They are usable evidence; they are not the same
  # evidence, so they do not share a value.
  @sources [:human, :llm, :agent]
  @splits [:calibration, :test, :train]
  @grade_scale 0..3

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "labeled_pairs" do
    field(:query_ref, :string)
    field(:query_text, :string)
    field(:memory_ref, :string)
    field(:grade, :integer)
    field(:source, Ecto.Enum, values: @sources)
    field(:split, Ecto.Enum, values: @splits)
    field(:judge_model, :string)

    belongs_to(:bank, Foresight.Schemas.Bank)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(labeled_pair, attrs) do
    labeled_pair
    |> cast(attrs, [
      :bank_id,
      :query_ref,
      :query_text,
      :memory_ref,
      :grade,
      :source,
      :split,
      :judge_model
    ])
    |> validate_required([:bank_id, :query_ref, :memory_ref, :grade, :source, :split])
    |> validate_inclusion(:grade, @grade_scale)
    |> validate_judge_model_presence()
    |> unique_constraint(:query_ref, name: :labeled_pairs_bank_query_memory_source_idx)
  end

  # Machine labels must record their judge (for kappa attribution + provenance); human
  # labels carry no model.
  defp validate_judge_model_presence(changeset) do
    case get_field(changeset, :source) do
      :llm ->
        if get_field(changeset, :judge_model) in [nil, ""],
          do: add_error(changeset, :judge_model, "is required for llm-sourced labels"),
          else: changeset

      _ ->
        changeset
    end
  end
end
