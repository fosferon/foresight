defmodule Foresight.Evals.Labeling.GoldIngestTest do
  @moduledoc """
  Parse a human-filled gold artifact into validated
  human-sourced label attrs. Pure: no DB.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.GoldIngest
  alias Foresight.Schemas.LabeledPair

  defp artifact(pairs) do
    %{"version" => 1, "bank_id" => "bank_eval", "pairs" => pairs}
  end

  defp pair(overrides) do
    Map.merge(
      %{
        "pair_id" => "q1::m1",
        "query_ref" => "q1",
        "query_text" => "when did I renew my passport?",
        "memory_ref" => "m1",
        "split" => "calibration",
        "grade" => 3
      },
      overrides
    )
  end

  test "turns graded pairs into human-sourced label attrs" do
    %{labels: [attrs], errors: [], skipped: 0} =
      GoldIngest.parse(artifact([pair(%{"grade" => 2, "split" => "test"})]))

    assert attrs.bank_id == "bank_eval"
    assert attrs.query_ref == "q1"
    assert attrs.memory_ref == "m1"
    assert attrs.grade == 2
    assert attrs.source == :human
    assert attrs.split == :test
    refute Map.has_key?(attrs, :judge_model)
  end

  test "skips ungraded (nil grade) pairs" do
    %{labels: labels, skipped: skipped} =
      GoldIngest.parse(
        artifact([pair(%{"grade" => nil}), pair(%{"pair_id" => "q2::m2", "grade" => 1})])
      )

    assert length(labels) == 1
    assert skipped == 1
  end

  test "collects invalid grades as errors instead of labels" do
    %{labels: labels, errors: errors} =
      GoldIngest.parse(
        artifact([
          pair(%{"pair_id" => "bad_hi", "grade" => 5}),
          pair(%{"pair_id" => "bad_str", "grade" => "banana"}),
          pair(%{"pair_id" => "ok", "grade" => 0})
        ])
      )

    assert length(labels) == 1
    assert length(errors) == 2
    assert Enum.any?(errors, &(&1.pair_id == "bad_hi"))
    assert Enum.any?(errors, &(&1.pair_id == "bad_str"))
  end

  test "accepts a string-digit grade" do
    %{labels: [attrs], errors: []} =
      GoldIngest.parse(artifact([pair(%{"grade" => "2"})]))

    assert attrs.grade == 2
  end

  test "rejects an unknown split" do
    %{labels: labels, errors: [error]} =
      GoldIngest.parse(artifact([pair(%{"split" => "holdout"})]))

    assert labels == []
    assert error.pair_id == "q1::m1"
  end

  test "rejects human train labels" do
    %{labels: [], errors: [%{reason: :unknown_split}]} =
      GoldIngest.parse(artifact([pair(%{"split" => "train"})]))
  end

  test "emitted attrs satisfy the LabeledPair changeset" do
    %{labels: [attrs]} = GoldIngest.parse(artifact([pair(%{})]))
    changeset = LabeledPair.changeset(%LabeledPair{}, attrs)
    assert changeset.valid?
  end
end
