defmodule Foresight.Evals.LongMemEvalTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.Dataset
  alias Foresight.Evals.LongMemEval

  # A SYNTHETIC instance in the LongMemEval shape — authored here, not drawn from the
  # corpus, so the loader is tested without redistributing any dataset content.
  defp synthetic do
    %{
      "question_id" => "syn_knowledge-update_1",
      "question_type" => "knowledge-update",
      "question" => "Where do I work now?",
      "answer" => "At the bakery on Mill Lane.",
      "question_date" => "2023/04/10 (Mon) 23:07",
      "haystack_session_ids" => ["s_old", "s_new", "s_noise"],
      "haystack_dates" => [
        "2023/01/02 (Mon) 09:00",
        "2023/03/01 (Wed) 09:00",
        "2023/02/15 (Wed) 09:00"
      ],
      "haystack_sessions" => [
        [%{"role" => "user", "content" => "I started at the library."}],
        [
          %{
            "role" => "user",
            "content" => "I moved to the Mill Lane bakery.",
            "has_answer" => true
          }
        ],
        [%{"role" => "user", "content" => "Nice weather today."}]
      ],
      "answer_session_ids" => ["s_new"]
    }
  end

  test "normalises a raw instance into a Dataset.Instance" do
    inst = LongMemEval.to_instance(synthetic())

    assert %Dataset{} = inst
    assert inst.id == "syn_knowledge-update_1"
    assert inst.question_type == "knowledge-update"
    assert inst.query == "Where do I work now?"
    assert inst.reference_answer == "At the bakery on Mill Lane."
    assert inst.query_timestamp == "2023-04-10T23:07:00Z"
    refute inst.abstention?
  end

  test "each session becomes one retain-ready memory keyed and labelled by session id" do
    inst = LongMemEval.to_instance(synthetic())

    assert length(inst.memories) == 3
    ids = Enum.map(inst.memories, & &1["id"])
    assert ids == ["s_old", "s_new", "s_noise"]

    # eval_id mirrored into metadata for result → label mapping
    for m <- inst.memories, do: assert(m["metadata"]["eval_id"] == m["id"])

    # dates normalised to ISO8601 so recency/temporal signals can parse them
    s_new = Enum.find(inst.memories, &(&1["id"] == "s_new"))
    assert s_new["mentioned_at"] == "2023-03-01T09:00:00Z"
    assert s_new["content"] =~ "Mill Lane bakery"
    # turn-level has_answer flags preserved for finer labelling later
    assert s_new["metadata"]["has_answer_turns"] == [0]
  end

  test "relevance labels only the answer sessions" do
    inst = LongMemEval.to_instance(synthetic())

    assert inst.relevance == %{"s_old" => 0, "s_new" => 1, "s_noise" => 0}
    # the metrics see: one relevant memory (s_new) among three
    assert Enum.count(inst.relevance, fn {_id, g} -> g > 0 end) == 1
  end

  test "abstention instances are flagged by the _abs question id suffix" do
    inst = LongMemEval.to_instance(%{synthetic() | "question_id" => "syn_multi-session_2_abs"})
    assert inst.abstention?
  end

  test "ranked_eval_ids extracts ordered ids from a recall response's results" do
    results = [
      %{"metadata" => %{"eval_id" => "s_new"}},
      %{"metadata" => %{"eval_id" => "s_old"}},
      %{"metadata" => %{}}
    ]

    assert Dataset.ranked_eval_ids(results) == ["s_new", "s_old"]
  end
end
