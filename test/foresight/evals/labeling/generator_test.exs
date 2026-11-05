defmodule Foresight.Evals.Labeling.GeneratorTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.Dataset
  alias Foresight.Evals.Labeling.Generator
  alias Mix.Tasks.Foresight.Labeling.Generate

  test "orchestrates retain, consolidate, recall, and builds the frozen 40/110 artifact" do
    parent = self()

    instances =
      for type <-
            ~w(knowledge-update multi-session single-session-assistant single-session-preference single-session-user temporal-reasoning),
          query <- 1..5 do
        %Dataset{
          id: "#{type}-#{query}",
          query: "question #{type} #{query}",
          question_type: type,
          memories: [
            %{
              "id" => "memory-#{type}-#{query}",
              "content" => "memory",
              "metadata" => %{}
            }
          ],
          relevance: %{}
        }
      end

    retain = fn ctx, memories ->
      send(parent, {:retain, ctx.bank, memories})
      {:ok, %{"items_count" => length(memories)}}
    end

    consolidate = fn ctx ->
      send(parent, {:consolidate, ctx.bank})
      {:ok, %{"observations_created" => 0}}
    end

    recall = fn ctx, payload ->
      send(parent, {:recall, ctx.bank, payload})

      candidates =
        for i <- 1..10 do
          %{
            memory_ref: "#{ctx.bank}-memory-#{i}",
            memory_id: "unit-#{i}",
            content: "candidate #{i}",
            context: "chat",
            arms: ["semantic"],
            best_rank: i
          }
        end

      {:ok, %{"candidate_pool" => %{candidates: candidates, dropped: []}}}
    end

    assert {:ok, result} =
             Generator.generate(instances,
               bank_id: "d2-lme-s",
               per_type: 5,
               seed: 42,
               target_pairs: 150,
               calibration_ratio: 0.267,
               per_query_cap: 10,
               top_k: 20,
               retain: retain,
               consolidate: consolidate,
               recall: recall
             )

    assert length(result.query_pools) == 30
    assert length(result.artifact["pairs"]) == 150
    assert Enum.count(result.artifact["pairs"], &(&1["split"] == "calibration")) == 40
    assert Enum.count(result.artifact["pairs"], &(&1["split"] == "test")) == 110

    assert_receive {:retain, query_bank, [memory]}
    assert String.starts_with?(query_bank, "d2-lme-s-")
    assert get_in(memory, ["metadata", "eval_id"]) == memory["id"]
    assert_receive {:consolidate, ^query_bank}

    assert_receive {:recall, ^query_bank,
                    %{
                      "include" => %{"candidate_pool" => %{"top_k" => 20}},
                      "query" => _
                    }}
  end

  test "returns the failing orchestration stage without fabricating a pool" do
    instance = %Dataset{
      id: "q-1",
      query: "question",
      question_type: "single-session-user",
      memories: [%{"id" => "m-1", "content" => "memory"}],
      relevance: %{}
    }

    assert {:error, %{stage: :retain, query_ref: "q-1", reason: :database_down}} =
             Generator.generate([instance],
               bank_id: "d2-lme-s",
               per_type: 1,
               retain: fn _ctx, _memories -> {:error, :database_down} end,
               consolidate: fn _ctx -> flunk("must not consolidate after failed retain") end,
               recall: fn _ctx, _payload -> flunk("must not recall after failed retain") end
             )
  end

  test "backfills an undersized question-type stratum from the remaining corpus" do
    instances =
      for {type, count} <- [{"scarce", 1}, {"common", 5}], query <- 1..count do
        %Dataset{
          id: "#{type}-#{query}",
          query: "question #{type} #{query}",
          question_type: type,
          memories: [%{"id" => "memory-#{type}-#{query}", "content" => "memory"}],
          relevance: %{}
        }
      end

    assert {:ok, result} =
             Generator.generate(instances,
               bank_id: "d2-lme-s",
               per_type: 3,
               seed: 42,
               retain: fn _ctx, _memories -> {:ok, %{}} end,
               consolidate: fn _ctx -> {:ok, %{}} end,
               recall: fn ctx, _payload ->
                 candidate = %{
                   memory_ref: "#{ctx.bank}-memory",
                   memory_id: "unit",
                   content: "candidate",
                   context: "chat",
                   arms: ["semantic"],
                   best_rank: 1
                 }

                 {:ok, %{"candidate_pool" => %{candidates: [candidate], dropped: []}}}
               end
             )

    assert length(result.sampled_instances) == 6
    assert Enum.count(result.sampled_instances, &(&1.question_type == "scarce")) == 1
    assert Enum.count(result.sampled_instances, &(&1.question_type == "common")) == 5
  end

  test "refuses to overwrite a grading artifact unless forced" do
    path =
      Path.join(
        System.tmp_dir!(),
        "foresight-labeling-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, "{}")
    on_exit(fn -> File.rm(path) end)

    assert_raise Mix.Error, ~r/output already exists/, fn ->
      Generate.ensure_output_available!(path, false)
    end

    assert Generate.ensure_output_available!(path, true) == nil
  end
end
