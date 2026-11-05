defmodule Foresight.Evals.Labeling.GoldSetTest do
  @moduledoc """
  Build a stratified, deterministically-split gold set from
  per-query candidate pools, and serialize it to a human-gradeable artifact. Pure: no DB.
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.GoldSet

  defp query_pool(qref, qtype, n) do
    %{
      query_ref: qref,
      query_text: "question #{qref}",
      question_type: qtype,
      candidates:
        for i <- 1..n do
          %{
            memory_ref: "#{qref}_m#{i}",
            memory_id: "u_#{qref}_#{i}",
            content: "content #{i}",
            context: "ctx",
            arms: ["semantic"],
            best_rank: i
          }
        end
    }
  end

  defp pools do
    for t <- ["knowledge-update", "temporal-reasoning", "multi-session"],
        q <- 1..4,
        do: query_pool("#{t}_q#{q}", t, 8)
  end

  test "is deterministic under a fixed seed" do
    a = GoldSet.build(pools(), seed: 42, target_pairs: 24)
    b = GoldSet.build(pools(), seed: 42, target_pairs: 24)
    assert a == b
  end

  test "produces exactly target_pairs when enough candidates exist" do
    gold = GoldSet.build(pools(), seed: 42, target_pairs: 24)
    assert length(gold) == 24
  end

  test "respects per_query_cap" do
    gold = GoldSet.build(pools(), seed: 42, target_pairs: 36, per_query_cap: 2)
    counts = Enum.frequencies_by(gold, & &1.query_ref)
    assert Enum.all?(Map.values(counts), &(&1 <= 2))
  end

  test "stratifies across question types" do
    gold = GoldSet.build(pools(), seed: 42, target_pairs: 24)
    types = gold |> Enum.map(& &1.question_type) |> Enum.uniq() |> Enum.sort()
    assert types == ["knowledge-update", "multi-session", "temporal-reasoning"]
  end

  test "assigns every pair a calibration or test split, ~calibration_ratio calibration" do
    gold = GoldSet.build(pools(), seed: 42, target_pairs: 20, calibration_ratio: 0.4)
    assert Enum.all?(gold, &(&1.split in [:calibration, :test]))
    calib = Enum.count(gold, &(&1.split == :calibration))
    assert calib == 8
  end

  test "to_artifact yields a JSON-encodable structure with blank grades and a bank id" do
    gold = GoldSet.build(pools(), seed: 42, target_pairs: 6)
    artifact = GoldSet.to_artifact(gold, "bank_eval")

    assert artifact["bank_id"] == "bank_eval"
    assert is_list(artifact["pairs"])
    assert length(artifact["pairs"]) == 6

    pair = hd(artifact["pairs"])
    assert Map.has_key?(pair, "grade")
    assert pair["grade"] == nil
    assert is_binary(pair["query_ref"]) and is_binary(pair["memory_ref"])
    assert is_binary(pair["query_text"]) and is_binary(pair["content"])
    # a blank free-text notes field + an inline one-line grading rubric on every row
    assert pair["notes"] == ""
    assert is_binary(pair["rubric"]) and pair["rubric"] =~ "0"
    # round-trips through JSON without loss
    assert {:ok, _} = Jason.encode(artifact)
  end
end
