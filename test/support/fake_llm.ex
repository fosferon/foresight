defmodule Foresight.TestSupport.FakeLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  alias Foresight.Schemas.Document

  @impl true
  def complete_structured(prompt, _messages, response_module, opts) do
    maybe_sleep(opts)

    if response_module == Foresight.Prompts.ReflectPlanResponse do
      query = prompt[:query] || ""
      recalled_count = prompt[:recalled] |> List.wrap() |> length()
      needs_consolidation = recalled_count >= 2 and prompt[:mental_models] == []

      {:ok,
       struct(response_module,
         focus_query: query,
         needs_consolidation: needs_consolidation,
         answer_ready: not needs_consolidation,
         reason:
           if(needs_consolidation,
             do: "needs synthesized observation",
             else: "grounding sufficient"
           )
       )}
    else
      query = prompt[:query]
      mission = get_in(prompt, [:bank, :mission]) || ""

      disposition =
        prompt
        |> get_in([:bank, :disposition])
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)

      memory =
        prompt[:recalled]
        |> List.first()
        |> case do
          nil ->
            ""

          item ->
            expanded =
              case item["expanded_context"] do
                %{} = context ->
                  " expanded=#{context["document_text"] || context["chunk_text"] || ""}"

                _ ->
                  ""
              end

            "#{item["text"] || item["content"]}#{expanded}"
        end

      mental_model =
        prompt[:mental_models]
        |> List.first()
        |> case do
          nil -> ""
          item -> support_text(item)
        end

      directives =
        prompt[:directives]
        |> Enum.map_join(",", fn directive ->
          Map.get(directive, :name) || Map.get(directive, "name")
        end)

      plan =
        prompt[:loop]
        |> case do
          %{} = loop -> "plan=#{Map.get(loop, "reason") || Map.get(loop, :reason) || ""}"
          _ -> "plan="
        end

      {:ok,
       struct(
         response_module,
         text:
           "#{query} | #{mission} | #{disposition} | #{memory} | mental_model=#{mental_model} | directives=#{directives} | #{plan}",
         directive_compliance: %{
           "status" => if(directives == "", do: "none", else: "followed"),
           "notes" => if(directives == "", do: "no directives", else: "Applied #{directives}")
         },
         memory_ids:
           prompt[:recalled]
           |> List.wrap()
           |> Enum.reject(&((&1["type"] || &1[:type]) == "observation"))
           |> Enum.map(&(&1["id"] || &1[:id]))
           |> Enum.reject(&is_nil/1)
           |> Enum.take(2),
         mental_model_ids:
           prompt[:mental_models]
           |> List.wrap()
           |> Enum.map(&support_id/1)
           |> Enum.reject(&is_nil/1)
           |> Enum.take(2),
         observation_ids:
           prompt[:observations]
           |> Map.get("observations", [])
           |> Enum.map(&(&1["id"] || &1[:id]))
           |> Enum.reject(&is_nil/1)
           |> Enum.take(2)
       )}
    end
  end

  @impl true
  def complete_json_schema(prompt, _messages, schema, opts) do
    maybe_sleep(opts)

    if consolidation_schema?(schema) do
      {:ok, consolidation_ops(prompt)}
    else
      seed = prompt[:text] || prompt[:answer_text] || prompt[:query] || "structured"
      {:ok, materialize_schema(schema, seed)}
    end
  end

  # Recognizes the consolidation merge contract and emits a deterministic merge:
  # empty pool -> one CREATE joining the batch's facts; non-empty pool -> one
  # UPDATE folding the new facts into the first pooled observation. Lets tests
  # exercise the real merge/proof_count/supersession path without a live LLM.
  defp consolidation_schema?(%{
         "properties" => %{"creates" => _, "updates" => _, "deletes" => _}
       }),
       do: true

  defp consolidation_schema?(_schema), do: false

  defp consolidation_ops(prompt) do
    facts = prompt[:facts] || prompt["facts"] || []
    observations = prompt[:observations] || prompt["observations"] || []
    fact_ids = Enum.map(facts, &(&1["id"] || &1[:id]))

    merged_text =
      facts
      |> Enum.map(&(&1["content"] || &1[:content]))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" | ")

    cond do
      facts == [] ->
        %{"creates" => [], "updates" => [], "deletes" => []}

      observations != [] ->
        obs = List.first(observations)
        obs_id = obs["id"] || obs[:id]

        %{
          "creates" => [],
          "updates" => [
            %{"observation_id" => obs_id, "text" => merged_text, "source_fact_ids" => fact_ids}
          ],
          "deletes" => []
        }

      true ->
        %{
          "creates" => [%{"text" => merged_text, "source_fact_ids" => fact_ids}],
          "updates" => [],
          "deletes" => []
        }
    end
  end

  defp maybe_sleep(opts) do
    case Keyword.get(opts, :sleep_ms) do
      value when is_integer(value) and value > 0 -> Process.sleep(value)
      _ -> :ok
    end
  end

  defp materialize_schema(%{"type" => "object", "properties" => properties}, seed) do
    Map.new(properties, fn {key, property} -> {key, materialize_value(property, seed)} end)
  end

  defp materialize_schema(_schema, seed), do: %{"text" => seed}

  defp materialize_value(%{"type" => "string"}, seed), do: seed
  defp materialize_value(%{"type" => "boolean"}, _seed), do: true
  defp materialize_value(%{"type" => "integer"}, _seed), do: 1
  defp materialize_value(%{"type" => "number"}, _seed), do: 1.0
  defp materialize_value(%{"type" => "array"}, _seed), do: []

  defp materialize_value(%{"type" => "object", "properties" => properties}, seed),
    do: materialize_schema(%{"type" => "object", "properties" => properties}, seed)

  defp materialize_value(_property, seed), do: seed

  defp support_text(%Document{} = item),
    do: item.original_text || item.title || item.external_id || ""

  defp support_text(item),
    do: item["text"] || item[:text] || item["content"] || item[:content] || ""

  defp support_id(%Document{} = item), do: item.external_id || item.id
  defp support_id(item), do: item["id"] || item[:id]
end

defmodule Foresight.TestSupport.HallucinatingLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok, plan}

      {:ok, response} ->
        {:ok,
         %{
           response
           | memory_ids: ["bogus-memory-id"],
             mental_model_ids: ["bogus-mental-model-id"],
             observation_ids: ["bogus-observation-id"]
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.ProjectGateDriftLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok, plan}

      {:ok, response} ->
        drifted_memory_ids =
          prompt[:recalled]
          |> List.wrap()
          |> Enum.reject(&((&1["type"] || &1[:type]) == "observation"))
          |> Enum.map(&(&1["id"] || &1[:id]))
          |> Enum.reject(&is_nil/1)
          |> Enum.drop(1)
          |> Enum.take(1)

        {:ok, %{response | memory_ids: drifted_memory_ids}}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.LeakyAnswerLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok, plan}

      {:ok, response} ->
        {:ok,
         %{
           response
           | text:
               response.text <>
                 ~s(\n\n```json\n{"memory_ids":["mem-leak"],"observation_ids":["obs-leak"]}\n```)
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.SlowLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    Process.sleep(25)
    Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, response_module, opts)
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Process.sleep(25)
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.FollowUpPlanLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok,
         %{
           plan
           | focus_query: "beta",
             answer_ready: false,
             needs_consolidation: false,
             reason: "needs verification recall"
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.MultiStepPlanLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_multistep_plan_count, 0)
        Process.put(:foresight_multistep_plan_count, count + 1)

        next_query =
          case count do
            0 -> "beta"
            _ -> "gamma"
          end

        {:ok,
         %{
           plan
           | focus_query: next_query,
             answer_ready: false,
             needs_consolidation: false,
             reason: "needs iterative verification"
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.ThreeStepPlanLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @queries ["beta", "gamma", "delta"]

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_three_step_plan_count, 0)
        Process.put(:foresight_three_step_plan_count, count + 1)

        next_query = Enum.at(@queries, min(count, length(@queries) - 1))

        {:ok,
         %{
           plan
           | focus_query: next_query,
             answer_ready: false,
             needs_consolidation: false,
             reason: "needs iterative verification"
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.VerificationThenConsolidateLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_verification_then_consolidate_count, 0)
        Process.put(:foresight_verification_then_consolidate_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "needs verification recall"
              }

            _ ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: false,
                  needs_consolidation: true,
                  reason: "needs consolidation after verification"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.StopAfterVerificationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_stop_after_verification_count, 0)
        Process.put(:foresight_stop_after_verification_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "needs one verification recall"
              }

            _ ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: true,
                  needs_consolidation: false,
                  reason: "verification sufficient"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.MemoryMentalModelOnlyLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok, plan}

      {:ok, response} ->
        {:ok, %{response | observation_ids: []}}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DuplicateAfterVerificationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_duplicate_after_verification_count, 0)
        Process.put(:foresight_duplicate_after_verification_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "needs one verification recall"
              }

            _ ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "duplicate refinement suggested"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.BlankAfterVerificationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_blank_after_verification_count, 0)
        Process.put(:foresight_blank_after_verification_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | focus_query: "beta",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "needs one verification recall"
              }

            _ ->
              %{
                plan
                | focus_query: "   ",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "blank refinement suggested"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DuplicateInitialVerificationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok,
         %{
           plan
           | focus_query: "alpha",
             answer_ready: false,
             needs_consolidation: false,
             reason: "duplicate refinement suggested immediately"
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.BlankInitialVerificationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok,
         %{
           plan
           | focus_query: "   ",
             answer_ready: false,
             needs_consolidation: false,
             reason: "blank refinement suggested immediately"
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.ImmediateAnswerLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        {:ok,
         %{
           plan
           | answer_ready: true,
             needs_consolidation: false,
             reason: "grounding sufficient"
         }}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.EvidenceBreadthRefineLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_evidence_breadth_refine_count, 0)
        Process.put(:foresight_evidence_breadth_refine_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              shortfall_status =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("status")

              evidence_family_shortfall_class =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("evidence_family_shortfall_class")

              targeted_breadth_metric =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("targeted_breadth_metric")

              used_memory_evidence_family_count =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("used_memory_evidence_family_count", 0)

              used_primary_evidence_family_count =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("used_primary_evidence_family_count", 0)

              used_evidence_family_count =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("used_evidence_family_count", 0)

              used_derived_evidence_family_count =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("used_derived_evidence_family_count", 0)

              min_evidence_family_count =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("min_evidence_family_count", 0)

              next_query =
                cond do
                  shortfall_status == "blocked_low_evidence_family_diversity" and
                      targeted_breadth_metric == "used_memory_evidence_family_count" ->
                    "beta memory family"

                  shortfall_status == "blocked_low_evidence_family_diversity" and
                    evidence_family_shortfall_class == "derived_only_breadth" and
                      used_primary_evidence_family_count < min_evidence_family_count ->
                    "beta primary family"

                  shortfall_status == "blocked_low_evidence_family_diversity" and
                      used_memory_evidence_family_count < min_evidence_family_count ->
                    "beta memory family"

                  shortfall_status == "blocked_low_evidence_family_diversity" and
                    used_evidence_family_count < min_evidence_family_count and
                      used_derived_evidence_family_count == 0 ->
                    "beta memory family"

                  shortfall_status == "blocked_low_source_family_diversity" ->
                    "beta source"

                  shortfall_status == "blocked_low_source_lineage_diversity" ->
                    "beta source"

                  shortfall_status == "blocked_low_source_provenance" ->
                    "beta source"

                  shortfall_status == "blocked_low_evidence_family_diversity" and
                      used_derived_evidence_family_count > 0 ->
                    "beta primary family"

                  true ->
                    "beta family"
                end

              %{
                plan
                | focus_query: next_query,
                  answer_ready: false,
                  needs_consolidation: false,
                  refinement_intent:
                    case shortfall_status do
                      "blocked_low_source_family_diversity" -> "source_family_breadth"
                      "blocked_low_source_lineage_diversity" -> "source_lineage_breadth"
                      "blocked_low_source_provenance" -> "source_provenance_breadth"
                      _ -> nil
                    end,
                  reason: "need broader evidence breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.MemorySourceRetryLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_memory_source_retry_count, 0)
        Process.put(:foresight_memory_source_retry_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "bridge clue",
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "need broader raw-memory evidence breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.TargetedBreadthMetricLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_targeted_breadth_metric_count, 0)
        Process.put(:foresight_targeted_breadth_metric_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              targeted_breadth_metric =
                prompt
                |> Map.get(:evidence_shortfall, %{})
                |> Map.get("targeted_breadth_metric")

              focus_query =
                case targeted_breadth_metric do
                  "used_memory_evidence_family_count" -> "beta memory family"
                  _ -> "beta family"
                end

              %{
                plan
                | focus_query: focus_query,
                  answer_ready: false,
                  needs_consolidation: false,
                  reason: "follow targeted breadth metric"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectMemorySourceIntentLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_memory_source_intent_count, 0)
        Process.put(:foresight_direct_memory_source_intent_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "bridge via sources seed",
                  answer_ready: false,
                  needs_consolidation: false,
                  refinement_intent: "memory_source_breadth",
                  reason: "broaden raw memories through source-linked evidence"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectMemorySourceNoProgressLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_memory_source_no_progress_count, 0)
        Process.put(:foresight_direct_memory_source_no_progress_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "bridge clue",
                  answer_ready: false,
                  needs_consolidation: false,
                  refinement_intent: "memory_source_breadth",
                  reason: "try a source-linked raw-memory verification directly"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectMemorySourceThenMemoryRetryLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_memory_source_then_retry_count, 0)
        Process.put(:foresight_direct_memory_source_then_retry_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "beta memory family",
                  answer_ready: false,
                  needs_consolidation: false,
                  refinement_intent: "memory_source_then_memory_breadth",
                  reason: "try a source-linked pass first, then broaden raw memories directly"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.SourceProvenanceRetrySuccessLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_source_provenance_retry_success_count, 0)
        Process.put(:foresight_source_provenance_retry_success_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "delta",
                  answer_ready: false,
                  needs_consolidation: false,
                  refinement_intent: "source_provenance_breadth",
                  reason: "need broader raw source provenance breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectSourceFamilyConsolidationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_source_family_consolidation_count, 0)
        Process.put(:foresight_direct_source_family_consolidation_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "beta source",
                  answer_ready: false,
                  needs_consolidation: true,
                  refinement_intent: "source_family_breadth",
                  reason: "consolidate to broaden source-family evidence breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectSourceFamilyConsolidationNoProgressLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_source_family_consolidation_no_progress_count, 0)
        Process.put(:foresight_direct_source_family_consolidation_no_progress_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "beta source",
                  answer_ready: false,
                  needs_consolidation: true,
                  refinement_intent: "source_family_breadth",
                  reason: "consolidate to broaden source-family evidence breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectSourceLineageConsolidationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_source_lineage_consolidation_count, 0)
        Process.put(:foresight_direct_source_lineage_consolidation_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "beta source",
                  answer_ready: false,
                  needs_consolidation: true,
                  refinement_intent: "source_lineage_breadth",
                  reason: "consolidate to broaden source-lineage evidence breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end

defmodule Foresight.TestSupport.DirectSourceProvenanceConsolidationLLM do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, messages, response_module, opts) do
    case Foresight.TestSupport.FakeLLM.complete_structured(
           prompt,
           messages,
           response_module,
           opts
         ) do
      {:ok, %Foresight.Prompts.ReflectPlanResponse{} = plan} ->
        count = Process.get(:foresight_direct_source_provenance_consolidation_count, 0)
        Process.put(:foresight_direct_source_provenance_consolidation_count, count + 1)

        next_plan =
          case count do
            0 ->
              %{
                plan
                | answer_ready: true,
                  needs_consolidation: false,
                  reason: "initial grounding seems sufficient"
              }

            _ ->
              %{
                plan
                | focus_query: "beta provenance",
                  answer_ready: false,
                  needs_consolidation: true,
                  refinement_intent: "source_provenance_breadth",
                  reason: "consolidate to broaden raw source provenance breadth"
              }
          end

        {:ok, next_plan}

      other ->
        other
    end
  end

  @impl true
  def complete_json_schema(prompt, messages, schema, opts) do
    Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end
end
