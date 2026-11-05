defmodule Foresight.LLMs.StructuredRecoveryTest do
  @moduledoc "Unit tests for fenced/loose-JSON structured-output recovery."
  use ExUnit.Case, async: true

  alias Foresight.LLMs.StructuredRecovery

  describe "recover/1" do
    test "recovers a map from a ```json-fenced invalid_json error" do
      raw = "```json\n{\"facts\": [{\"what\": \"x\"}]}\n```"
      reason = {:structured_output_error, {:invalid_json, %{data: raw}}}
      assert {:ok, %{"facts" => [%{"what" => "x"}]}} = StructuredRecovery.recover(reason)
    end

    test "recovers despite a trailing comma before a closing bracket" do
      raw = "```json\n{\"creates\": [{\"text\": \"a\"},], \"updates\": [], \"deletes\": []}\n```"
      reason = {:structured_output_error, {:invalid_json, %{data: raw}}}

      assert {:ok, %{"creates" => [%{"text" => "a"}], "updates" => [], "deletes" => []}} =
               StructuredRecovery.recover(reason)
    end

    test "recovers from a bare %{data: raw} error shape" do
      assert {:ok, %{"k" => 1}} = StructuredRecovery.recover(%{data: "```json\n{\"k\": 1}\n```"})
    end

    test "returns :error for unrecognized reasons or non-JSON bodies" do
      assert :error = StructuredRecovery.recover(:some_other_error)

      assert :error =
               StructuredRecovery.recover(
                 {:structured_output_error, {:invalid_json, %{data: "not json at all"}}}
               )

      assert :error = StructuredRecovery.recover(%{data: 123})
    end
  end

  describe "recover_struct/2 (Note: make reflect structured calls fence-robust)" do
    alias Foresight.Prompts.ReflectPlanResponse

    test "recovers a fenced reflect-plan JSON into the response struct" do
      # gpt-oss:20b wraps its structured decision in a ```json fence; the reflect
      # agentic loop's complete_structured call must recover it into the struct
      # rather than hard-failing the whole reflect (the parity/fairness bug).
      raw =
        "```json\n{\"focus_query\": \"how many negronis?\", \"needs_consolidation\": true, " <>
          "\"answer_ready\": false, \"reason\": \"need more\"}\n```"

      reason = {:structured_output_error, {:invalid_json, %{data: raw}}}

      assert {:ok,
              %ReflectPlanResponse{
                focus_query: "how many negronis?",
                needs_consolidation: true,
                answer_ready: false,
                reason: "need more"
              }} = StructuredRecovery.recover_struct(reason, ReflectPlanResponse)
    end

    test "ignores unknown JSON keys, keeps only struct fields" do
      raw =
        "```json\n{\"focus_query\": \"q\", \"needs_consolidation\": false, " <>
          "\"answer_ready\": true, \"bogus\": 9}\n```"

      reason = {:structured_output_error, {:invalid_json, %{data: raw}}}

      assert {:ok, %ReflectPlanResponse{focus_query: "q", answer_ready: true}} =
               StructuredRecovery.recover_struct(reason, ReflectPlanResponse)
    end

    test "returns :error for unrecoverable reasons (caller keeps the original error)" do
      assert :error = StructuredRecovery.recover_struct(:nope, ReflectPlanResponse)

      assert :error =
               StructuredRecovery.recover_struct(
                 {:structured_output_error, {:invalid_json, %{data: "not json"}}},
                 ReflectPlanResponse
               )
    end
  end

  describe "decode_lenient/1" do
    test "handles un-fenced JSON too" do
      assert {:ok, %{"a" => 1}} = StructuredRecovery.decode_lenient(~s({"a": 1}))
    end

    test "strips ```-only fences (no json tag)" do
      assert {:ok, %{"a" => 1}} = StructuredRecovery.decode_lenient("```\n{\"a\": 1}\n```")
    end
  end
end
