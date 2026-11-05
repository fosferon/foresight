defmodule Foresight.Evals.Labeling.PipelineTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.Labeling.Pipeline

  defp artifact do
    %{
      "version" => 1,
      "bank_id" => "bank-1",
      "marker" => "preserve me",
      "pairs" => [
        %{
          "pair_id" => "q1::m1",
          "query_ref" => "q1",
          "query_text" => "question one",
          "memory_ref" => "m1",
          "content" => "memory one",
          "context" => "context one",
          "split" => "calibration",
          "grade" => nil,
          "notes" => ""
        },
        %{
          "pair_id" => "q1::m2",
          "query_ref" => "q1",
          "query_text" => "question one",
          "memory_ref" => "m2",
          "content" => "memory two",
          "context" => "context two",
          "split" => "test",
          "grade" => nil,
          "notes" => ""
        }
      ]
    }
  end

  test "turns gold rows into judge pairs while preserving calibration and test splits" do
    assert [
             %{
               bank_id: "bank-1",
               query_ref: "q1",
               query_text: "question one",
               memory_ref: "m1",
               content: "memory one",
               context: "context one",
               split: :calibration
             },
             %{memory_ref: "m2", split: :test}
           ] = Pipeline.gold_judge_pairs(artifact())

    refute Map.has_key?(hd(Pipeline.gold_judge_pairs(artifact())), :grade)
  end

  test "derives deduped train pairs from mixed-key pools and excludes all gold pairs" do
    sidecar = %{
      bank_id: "bank-1",
      query_pools: [
        %{
          query_ref: "q1",
          query_text: "question one",
          candidates: [
            %{memory_ref: "m1", content: "gold calibration"},
            %{"memory_ref" => "m2", "content" => "gold test"},
            %{"memory_ref" => "m3", "content" => "train exemplar", "context" => "ctx"},
            %{memory_ref: "m3", content: "duplicate"}
          ]
        },
        %{
          "query_ref" => "q2",
          "query_text" => "question two",
          "candidates" => [
            %{"memory_ref" => "m3", "content" => "same memory, different query"}
          ]
        }
      ]
    }

    assert [
             %{
               bank_id: "bank-1",
               query_ref: "q1",
               memory_ref: "m3",
               content: "train exemplar",
               context: "ctx",
               split: :train
             },
             %{
               bank_id: "bank-1",
               query_ref: "q2",
               memory_ref: "m3",
               split: :train
             }
           ] = Pipeline.train_judge_pairs(sidecar, artifact())
  end

  test "selects only requested judge splits for a scoped rerun" do
    sidecar = %{
      "bank_id" => "bank-1",
      "query_pools" => [
        %{
          "query_ref" => "q1",
          "query_text" => "question one",
          "candidates" => [
            %{"memory_ref" => "m1", "content" => "gold calibration"},
            %{"memory_ref" => "m2", "content" => "gold test"},
            %{"memory_ref" => "m3", "content" => "train exemplar"}
          ]
        }
      ]
    }

    assert [
             %{memory_ref: "m1", split: :calibration},
             %{memory_ref: "m3", split: :train}
           ] = Pipeline.judge_pairs(sidecar, artifact(), [:calibration, :train])
  end

  test "prefills only test rows from successful llm labels and preserves artifact content" do
    labels = %{
      labels: [
        %{
          bank_id: "bank-1",
          query_ref: "q1",
          memory_ref: "m1",
          grade: 3,
          source: :llm,
          judge_reason: "hidden calibration reason"
        },
        %{
          "bank_id" => "bank-1",
          "query_ref" => "q1",
          "memory_ref" => "m2",
          "grade" => 2,
          "source" => "llm",
          "judge_reason" => "partially relevant"
        }
      ]
    }

    prefilled = Pipeline.prefill_test_artifact(artifact(), labels)
    [calibration, test] = prefilled["pairs"]

    assert calibration["grade"] == nil
    refute Map.has_key?(calibration, "judge_reason")
    assert test["grade"] == 2
    assert test["judge_reason"] == "partially relevant"
    assert test["notes"] == ""
    assert prefilled["marker"] == "preserve me"
  end

  test "reports the 4x4 bank-scoped confusion matrix and passes at kappa >= 0.6" do
    rows =
      for grade <- 0..3, source <- [:human, :llm] do
        %{
          bank_id: "bank-1",
          query_ref: "q#{grade}",
          memory_ref: "m#{grade}",
          grade: grade,
          source: source,
          split: :calibration
        }
      end ++
        [
          %{
            bank_id: "other-bank",
            query_ref: "q0",
            memory_ref: "m0",
            grade: 3,
            source: :llm,
            split: :calibration
          }
        ]

    report = Pipeline.calibration_report(rows, bank_id: "bank-1")

    assert report.n == 4
    assert report.kappa == 1.0
    assert report.passed?
    assert report.threshold == 0.6

    assert report.confusion == [
             [1, 0, 0, 0],
             [0, 1, 0, 0],
             [0, 0, 1, 0],
             [0, 0, 0, 1]
           ]
  end

  test "fails the gate when kappa is below threshold or undefined" do
    disagreeing =
      for {query_ref, human_grade, llm_grade} <- [
            {"q0", 0, 3},
            {"q1", 1, 2},
            {"q2", 2, 1},
            {"q3", 3, 0}
          ],
          {source, grade} <- [{:human, human_grade}, {:llm, llm_grade}] do
        %{
          "bank_id" => "bank-1",
          "query_ref" => query_ref,
          "memory_ref" => "memory",
          "grade" => Integer.to_string(grade),
          "source" => Atom.to_string(source),
          "split" => "calibration"
        }
      end

    refute Pipeline.calibration_report(disagreeing).passed?

    undefined =
      Pipeline.calibration_report([
        %{
          bank_id: "bank-1",
          query_ref: "q",
          memory_ref: "m",
          grade: 3,
          source: :human,
          split: :calibration
        },
        %{
          bank_id: "bank-1",
          query_ref: "q",
          memory_ref: "m",
          grade: 3,
          source: :llm,
          split: :calibration
        }
      ])

    assert undefined.kappa == nil
    assert undefined.n == 1
    refute undefined.passed?
  end

  # Note: the reference side of the gate is agent-graded, not human-graded. The report
  # must name which reference set it scored against so no reader can assume the stronger
  # claim from the number alone.
  test "gates against agent-sourced reference rows and names the reference set" do
    rows =
      for grade <- 0..3, source <- [:agent, :llm] do
        %{
          bank_id: "bank-1",
          query_ref: "q#{grade}",
          memory_ref: "m#{grade}",
          grade: grade,
          source: source,
          split: :calibration
        }
      end

    report = Pipeline.calibration_report(rows, bank_id: "bank-1")

    assert report.reference_source == :agent
    assert report.n == 4
    assert report.kappa == 1.0
    assert report.passed?
  end

  test "still names human as the reference set when human rows are present" do
    rows =
      for grade <- 0..3, source <- [:human, :llm] do
        %{
          bank_id: "bank-1",
          query_ref: "q#{grade}",
          memory_ref: "m#{grade}",
          grade: grade,
          source: source,
          split: :calibration
        }
      end

    assert Pipeline.calibration_report(rows, bank_id: "bank-1").reference_source == :human
  end

  test "refuses to mix reference sources when both are present" do
    rows =
      for grade <- 0..3, source <- [:human, :agent, :llm] do
        %{
          bank_id: "bank-1",
          query_ref: "q#{grade}",
          memory_ref: "m#{grade}",
          grade: grade,
          source: source,
          split: :calibration
        }
      end

    # An explicit choice is required rather than a silent precedence rule, because
    # silently preferring one would misreport which set the gate actually used.
    assert_raise ArgumentError, ~r/both :human and :agent/, fn ->
      Pipeline.calibration_report(rows, bank_id: "bank-1")
    end

    assert Pipeline.calibration_report(rows, bank_id: "bank-1", reference_source: :agent).reference_source ==
             :agent
  end
end
