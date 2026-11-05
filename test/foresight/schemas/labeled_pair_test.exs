defmodule Foresight.Schemas.LabeledPairTest do
  @moduledoc """
  Relevance-labeling substrate. A LabeledPair is one source's graded
  relevance for a (query, candidate memory) pair. Candidates are keyed on the stable
  corpus id (`memory_ref` = metadata["eval_id"]), never the ephemeral memory_unit UUID,
  so human gold labels survive corpus reloads.
  """
  use ExUnit.Case, async: true

  alias Foresight.Schemas.LabeledPair

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        bank_id: "bank_eval",
        query_ref: "q_0001",
        query_text: "When did I last renew my passport?",
        memory_ref: "session_42",
        grade: 3,
        source: :human,
        split: :test
      },
      overrides
    )
  end

  test "accepts a well-formed human label" do
    changeset = LabeledPair.changeset(%LabeledPair{}, valid_attrs())
    assert changeset.valid?
  end

  test "requires the identifying + grading fields" do
    for field <- [:bank_id, :query_ref, :memory_ref, :grade, :source, :split] do
      attrs = Map.delete(valid_attrs(), field)
      changeset = LabeledPair.changeset(%LabeledPair{}, attrs)
      refute changeset.valid?, "expected missing #{field} to invalidate"
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "grade must be within the 0..3 graded-relevance scale" do
    for bad <- [-1, 4, 10] do
      changeset = LabeledPair.changeset(%LabeledPair{}, valid_attrs(%{grade: bad}))
      refute changeset.valid?, "expected grade #{bad} to be rejected"
      assert Keyword.has_key?(changeset.errors, :grade)
    end

    for ok <- [0, 1, 2, 3] do
      changeset = LabeledPair.changeset(%LabeledPair{}, valid_attrs(%{grade: ok}))
      assert changeset.valid?, "expected grade #{ok} to be accepted"
    end
  end

  test "rejects unknown source and split values" do
    refute LabeledPair.changeset(%LabeledPair{}, valid_attrs(%{source: :robot})).valid?
    refute LabeledPair.changeset(%LabeledPair{}, valid_attrs(%{split: :nonsense})).valid?
  end

  test "llm-sourced labels must record which judge produced them" do
    llm_no_model =
      LabeledPair.changeset(%LabeledPair{}, valid_attrs(%{source: :llm, split: :train}))

    refute llm_no_model.valid?, "llm label without judge_model must be rejected"
    assert Keyword.has_key?(llm_no_model.errors, :judge_model)

    llm_with_model =
      LabeledPair.changeset(
        %LabeledPair{},
        valid_attrs(%{source: :llm, split: :train, judge_model: "zai/glm-5.2"})
      )

    assert llm_with_model.valid?
  end

  test "human-sourced labels need no judge_model" do
    changeset = LabeledPair.changeset(%LabeledPair{}, valid_attrs(%{source: :human}))
    assert changeset.valid?
    refute Keyword.has_key?(changeset.errors, :judge_model)
  end
end
