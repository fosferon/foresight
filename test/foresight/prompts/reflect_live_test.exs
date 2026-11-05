defmodule Foresight.Prompts.ReflectLiveTest do
  use ExUnit.Case, async: false

  alias Foresight.Evals.RecallQuality
  alias Foresight.LLMs.LlmCore
  alias Foresight.Prompts.{ReflectPlanResponse, ReflectResponse}

  @moduletag :ml
  @moduletag timeout: 300_000

  setup do
    if not lmstudio_available?() do
      {:ok, skip: "LMStudio is not available on http://127.0.0.1:1234/v1"}
    else
      original_engine = Application.get_env(:foresight, :engine)

      Application.put_env(:foresight, :engine,
        storage: Foresight.Storage.Ecto,
        repo: Foresight.Repo,
        embedder: Foresight.Embedders.Noop,
        llm: Foresight.LLMs.LlmCore,
        provider: "openai",
        provider_opts: [
          base_url: "http://127.0.0.1:1234/v1",
          api_key: "lm-studio",
          model: lmstudio_model!(),
          timeout: 180_000
        ]
      )

      on_exit(fn ->
        if original_engine do
          Application.put_env(:foresight, :engine, original_engine)
        else
          Application.delete_env(:foresight, :engine)
        end
      end)

      :ok
    end
  end

  test "reflect planner prompt returns a structured plan through LMStudio" do
    prompt =
      Foresight.Prompts.Reflect.Plan.V1.build(
        "What did Alice and I decide about the Foresight cutover after Oxford?",
        %{"budget" => "low"},
        bank_profile(),
        recalled_results(),
        observations(),
        [],
        []
      )

    assert {:ok, %ReflectPlanResponse{} = plan} =
             LlmCore.complete_structured(prompt, [], ReflectPlanResponse, [])

    assert is_binary(plan.focus_query)
    assert String.trim(plan.focus_query) != ""
    assert is_boolean(plan.needs_consolidation)
    assert is_boolean(plan.answer_ready)
  end

  test "reflect synthesis prompt returns grounded structured output through LMStudio" do
    prompt =
      Foresight.Prompts.Reflect.V1.build(
        "What did Alice and I decide about the Foresight cutover after Oxford?",
        %{"budget" => "low"},
        bank_profile(),
        recalled_results(),
        observations(),
        [],
        [],
        %{
          reason: "planner marked the current evidence sufficient",
          answer_ready: true,
          needs_consolidation: false,
          max_iterations: 1
        }
      )

    assert {:ok, %ReflectResponse{} = response} =
             LlmCore.complete_structured(prompt, [], ReflectResponse, [])

    assert is_binary(response.text)
    assert String.trim(response.text) != ""
    assert topic_match?(response.text, ["foresight", "cutover", "oxford", "lmstudio"])
    assert is_map(response.directive_compliance)
    assert is_list(response.memory_ids)
    assert response.memory_ids != []
  end

  test "reflect synthesis stays grounded across the correction frontier with shared evidence" do
    for scenario <- RecallQuality.reflect_scenarios() do
      prompt =
        Foresight.Prompts.Reflect.V1.build(
          scenario.query,
          %{"budget" => "low"},
          bank_profile(),
          frontier_recalled_results(),
          observations(),
          [],
          [],
          %{
            reason: "planner marked the current evidence sufficient",
            answer_ready: true,
            needs_consolidation: false,
            max_iterations: 1
          }
        )

      assert {:ok, %ReflectResponse{} = response} =
               LlmCore.complete_structured(prompt, [], ReflectResponse, [])

      assert is_binary(response.text)
      assert String.trim(response.text) != ""

      assert RecallQuality.matches_reflect_text?(scenario, response.text),
             "scenario=#{scenario.id} response mismatch: #{inspect(response.text)}"

      refute String.contains?(
               String.downcase(response.text),
               "i don't have enough grounded information"
             )

      required_memory_ids = Map.get(scenario, :required_memory_ids, [])

      assert Enum.all?(required_memory_ids, &(&1 in response.memory_ids)),
             "scenario=#{scenario.id} missing required memory ids: expected #{inspect(required_memory_ids)} got #{inspect(response.memory_ids)}"
    end
  end

  defp bank_profile do
    %{
      "bank_id" => "diary-ml-bank",
      "name" => "Diary ML Bank",
      "mission" => "Remember diary facts faithfully and avoid invention.",
      "disposition" => %{"skepticism" => 7, "empathy" => 6}
    }
  end

  defp recalled_results do
    [
      %{
        "id" => "mem-1",
        "text" =>
          "After visiting the Ashmolean in Oxford, Alice and I agreed to delay the Foresight cutover until the LMStudio reflect lane was proven.",
        "type" => "world",
        "score" => 0.99,
        "tags" => ["diary", "project:foresight", "person:alice", "place:oxford"]
      }
    ]
  end

  defp frontier_recalled_results do
    [
      %{
        "id" => "mem-corrected",
        "text" =>
          "Correction after the Oxford debrief: we did not approve an immediate Foresight launch; we delayed cutover until the LMStudio reflect lane was proven.",
        "type" => "world",
        "score" => 0.99,
        "tags" => ["project:foresight", "tool:lmstudio", "status:corrected", "place:oxford"]
      },
      %{
        "id" => "mem-latest",
        "text" =>
          "Latest decision after the Oxford debrief: keep the Python Hindsight authority in place and only cut helios-diary over once Foresight proved industrial-strength recall and reflect quality.",
        "type" => "world",
        "score" => 0.98,
        "tags" => [
          "project:hindsight",
          "project:helios-diary",
          "project:foresight",
          "status:latest"
        ]
      },
      %{
        "id" => "mem-gate",
        "text" =>
          "We wanted helios-diary to cut over only after the Foresight memory path felt industrial-strength under real recall and reflect load.",
        "type" => "world",
        "score" => 0.97,
        "tags" => ["project:helios-diary", "project:foresight", "topic:quality"]
      },
      %{
        "id" => "mem-fallback",
        "text" =>
          "We kept the Python Hindsight authority live as the fallback while the Foresight recall and reflect lane was being qualified.",
        "type" => "world",
        "score" => 0.96,
        "tags" => ["project:hindsight", "project:foresight", "topic:fallback", "status:active"]
      },
      %{
        "id" => "mem-not-port",
        "text" =>
          "Authority port instability came up, but it was not the governing cutover gate; the real bar was proving recall and reflect quality on diary-style memory.",
        "type" => "world",
        "score" => 0.95,
        "tags" => ["project:foresight", "topic:cutover", "topic:quality", "status:clarified"]
      },
      %{
        "id" => "mem-no-schedule",
        "text" =>
          "We did not set a next-week launch date; we waited for industrial-strength recall and reflect quality instead of a calendar-based cutover.",
        "type" => "world",
        "score" => 0.94,
        "tags" => ["project:foresight", "topic:schedule", "topic:quality", "status:clarified"]
      }
    ]
  end

  defp observations do
    %{
      "count" => 0,
      "freshness" => "unknown",
      "is_stale" => false,
      "observations" => []
    }
  end

  defp lmstudio_available? do
    case Req.get("http://127.0.0.1:1234/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> true
      _other -> false
    end
  end

  defp lmstudio_model! do
    case Req.get("http://127.0.0.1:1234/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status, body: %{"data" => [%{"id" => model} | _]}}}
      when status in 200..299 and is_binary(model) and model != "" ->
        model

      other ->
        raise "Unable to discover an LMStudio model: #{inspect(other)}"
    end
  end

  defp topic_match?(text, terms) when is_binary(text) do
    normalized = String.downcase(text)
    Enum.any?(terms, &String.contains?(normalized, &1))
  end
end
