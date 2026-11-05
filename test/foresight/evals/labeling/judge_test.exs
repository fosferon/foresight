defmodule Foresight.Evals.Labeling.JudgeTest do
  @moduledoc """
  LLM graded-relevance judge. Structure + parsing + seam wiring,
  exercised against fake LLMs; the live GLM-5.2 call is the only paid part. Pure otherwise.

  Integrity contract: on any LLM failure or an out-of-range grade the pair is SKIPPED and
  reported, never assigned a fabricated default grade (a default would bias fusion-weight training).
  """
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.Judge
  alias Foresight.Schemas.LabeledPair

  defmodule GradingLLM do
    @moduledoc false
    # Grades by a trivial rule so the test is deterministic: grade = String.length rem 4.
    def complete_json_schema(_prompt, messages, _schema, opts) do
      if pid = Process.get(:judge_test_pid) do
        send(pid, {:llm_opts, opts})
        send(pid, {:judge_messages, messages})
      end

      content = messages |> List.last() |> Map.get(:content)
      {:ok, %{"grade" => rem(String.length(content), 4), "reason" => "test"}}
    end
  end

  defmodule OutOfRangeLLM do
    @moduledoc false
    def complete_json_schema(_p, _m, _s, _o), do: {:ok, %{"grade" => 7}}
  end

  defmodule ErrorLLM do
    @moduledoc false
    def complete_json_schema(_p, _m, _s, _o), do: {:error, :unavailable}
  end

  defmodule MissingReasonLLM do
    @moduledoc false
    def complete_json_schema(_p, _m, _s, _o), do: {:ok, %{"grade" => 2}}
  end

  defmodule FlakyLLM do
    @moduledoc false

    def complete_json_schema(_p, _m, _s, _o) do
      attempt = Process.get(:judge_attempt, 0) + 1
      Process.put(:judge_attempt, attempt)

      if attempt == 1 do
        {:error, {:structured_output_error, :missing_content}}
      else
        {:ok, %{"grade" => 2, "reason" => "recovered"}}
      end
    end
  end

  defp pair(overrides \\ %{}) do
    Map.merge(
      %{
        bank_id: "bank_eval",
        query_ref: "q1",
        query_text: "when did I renew my passport?",
        memory_ref: "m1",
        content: "renewed passport in March",
        context: "ctx",
        split: :train
      },
      overrides
    )
  end

  test "produces llm-sourced label attrs recording the judge model" do
    Process.put(:judge_test_pid, self())

    %{labels: [attrs], errors: []} =
      Judge.label_all([pair()],
        llm: GradingLLM,
        judge_model: "glm-5.2",
        provider_opts: [model: "wrong-model"]
      )

    assert attrs.source == :llm
    assert attrs.judge_model == "glm-5.2@relevance-v1"
    assert attrs.grade in 0..3
    assert attrs.judge_reason == "test"
    assert attrs.query_ref == "q1" and attrs.memory_ref == "m1"
    assert attrs.split == :train
    assert_receive {:llm_opts, provider_opts: provider_opts}
    assert provider_opts[:model] == "glm-5.2"
  end

  test "states the strict relevance boundaries and multi-hop rule in the v2 rubric" do
    Process.put(:judge_test_pid, self())

    Judge.label_all([pair()], llm: GradingLLM, judge_model: "glm-5.2", rubric: "relevance-v2")

    assert_receive {:judge_messages, [%{role: :system, content: system}, %{role: :user}]}
    assert system =~ "Lexical or topical overlap alone is grade 0"
    assert system =~ "Grade 1 requires genuine engagement with the queried entity or topic"
    assert system =~ "one necessary step is grade 2"
    assert system =~ "Grade 3 requires direct answer-bearing evidence"
  end

  test "grades against a pinned earlier rubric version when asked" do
    Process.put(:judge_test_pid, self())

    %{labels: [attrs]} =
      Judge.label_all([pair()],
        llm: GradingLLM,
        judge_model: "glm-5.2",
        rubric: "relevance-v1"
      )

    assert_receive {:judge_messages, [%{role: :system, content: system}, %{role: :user}]}
    # v1 is the loose original rubric: no strict 0/1 boundary, no multi-hop clause.
    assert system =~ "3 = directly answers or is essential"
    refute system =~ "Lexical or topical overlap alone is grade 0"
    assert attrs.judge_model == "glm-5.2@relevance-v1"
  end

  test "rejects an unknown rubric version rather than silently grading" do
    assert_raise ArgumentError, ~r/unknown rubric/, fn ->
      Judge.label_all([pair()], llm: GradingLLM, judge_model: "glm-5.2", rubric: "nope")
    end
  end

  test "the recorded rubric version always matches the rubric text actually sent" do
    Process.put(:judge_test_pid, self())

    %{labels: [attrs]} =
      Judge.label_all([pair()],
        llm: GradingLLM,
        judge_model: "glm-5.2",
        rubric: "relevance-v2"
      )

    assert_receive {:judge_messages, [%{role: :system, content: system}, %{role: :user}]}
    assert attrs.judge_model == "glm-5.2@relevance-v2"
    assert system =~ "Lexical or topical overlap alone is grade 0"

    # There is no caller-supplied override of the persisted provenance: an unknown option
    # cannot make a label claim a rubric the judge never used.
    %{labels: [ignored]} =
      Judge.label_all([pair()],
        llm: GradingLLM,
        judge_model: "glm-5.2",
        label_model: "glm-5.2@relevance-v2"
      )

    assert ignored.judge_model == "glm-5.2@relevance-v1"
    assert_receive {:llm_opts, provider_opts: provider_opts}
    assert provider_opts[:model] == "glm-5.2"
  end

  test "emitted attrs satisfy the LabeledPair changeset" do
    %{labels: [attrs]} = Judge.label_all([pair()], llm: GradingLLM, judge_model: "zai/glm-5.2")
    assert LabeledPair.changeset(%LabeledPair{}, attrs).valid?
  end

  test "preserves the calibration split so the kappa join works" do
    %{labels: [attrs]} =
      Judge.label_all([pair(%{split: :calibration})], llm: GradingLLM, judge_model: "m")

    assert attrs.split == :calibration
  end

  test "skips and reports a pair on LLM error — no fabricated grade" do
    %{labels: labels, errors: [error]} =
      Judge.label_all([pair()], llm: ErrorLLM, judge_model: "m")

    assert labels == []
    assert error.query_ref == "q1" and error.memory_ref == "m1"
  end

  test "skips and reports an out-of-range grade rather than trusting it" do
    %{labels: [], errors: [error]} =
      Judge.label_all([pair()], llm: OutOfRangeLLM, judge_model: "m")

    assert error.reason == :grade_out_of_range
  end

  test "skips a grade that has no judge reason" do
    %{labels: [], errors: [%{reason: :missing_reason}]} =
      Judge.label_all([pair()], llm: MissingReasonLLM, judge_model: "m")
  end

  test "retries a failed pair without relabeling successful pairs" do
    Process.delete(:judge_attempt)

    %{labels: [%{grade: 2, judge_reason: "recovered"}], errors: []} =
      Judge.label_all([pair()],
        llm: FlakyLLM,
        judge_model: "m",
        max_attempts: 2
      )

    assert Process.get(:judge_attempt) == 2
  end

  test "an incapable llm skips every pair" do
    %{labels: [], errors: errors} =
      Judge.label_all([pair(), pair(%{memory_ref: "m2"})], llm: nil, judge_model: "m")

    assert length(errors) == 2
  end

  test "partitions labels and errors across a mixed batch" do
    pairs = [pair(%{memory_ref: "m1"}), pair(%{memory_ref: "m2"})]
    %{labels: labels, errors: errors} = Judge.label_all(pairs, llm: GradingLLM, judge_model: "m")
    assert length(labels) == 2
    assert errors == []
  end
end
