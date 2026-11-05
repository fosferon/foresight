defmodule Foresight.TestSupport.FakeEmbedder do
  @moduledoc false

  @behaviour Foresight.Embedder

  @impl true
  def dimension(opts), do: {:ok, Keyword.get(opts, :embedding_dim, 384)}

  @impl true
  def embed(text, opts) do
    dim = Keyword.get(opts, :embedding_dim, 384)
    value = if text == "", do: 0.0, else: 1.0
    {:ok, List.duplicate(value, dim)}
  end
end

defmodule Foresight.TestSupport.FakeEmbedder1024 do
  @moduledoc false

  @behaviour Foresight.Embedder

  @impl true
  def dimension(_opts), do: {:ok, 1024}

  @impl true
  def embed(text, _opts) do
    value = if text == "", do: 0.0, else: 2.0
    {:ok, List.duplicate(value, 1024)}
  end
end

defmodule Foresight.TestSupport.FakeStorage do
  @moduledoc false

  use Agent

  alias Foresight.Budget
  alias Foresight.EntityExtractors.Simple, as: EntityExtractor
  alias Foresight.Evals.Labeling.CandidatePool
  @behaviour Foresight.Storage
  alias Foresight.Error

  @semantic_similarity_floor 0.3
  @semantic_overfetch_multiplier 5
  @semantic_overfetch_min 100
  @graph_semantic_floor 0.7
  @graph_max_hops 3
  @graph_decay 0.7
  @temporal_entry_point_limit 50
  @temporal_similarity_floor 0.1
  @temporal_result_limit 10
  @temporal_link_boost 1.5
  @temporal_entry_boost 2.0
  @temporal_decay 0.7
  @temporal_per_source_limit 10
  @temporal_max_hops 5
  @unsupported_recall_fields ~w(after before limit offset)
  @leaked_json_suffix ~r/\s*```(?:json)?\s*\{[^}]*(?:"(?:observation_ids|memory_ids|mental_model_ids)"|\})\s*```\s*$/si
  @leaked_json_object ~r/\s*\{[^{]*"(?:observation_ids|memory_ids|mental_model_ids|answer)"[^}]*\}\s*$/s
  @trailing_ids_pattern ~r/\s*(?:observation_ids|memory_ids|mental_model_ids)\s*[=:]\s*\[.*?\]\s*$/si

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          banks: %{},
          memory_units: [],
          audit_logs: [],
          documents: %{},
          entities: %{},
          entity_links: %{},
          directives: %{},
          mental_models: %{}
        }
      end,
      name: __MODULE__
    )
  end

  def reset! do
    Agent.update(__MODULE__, fn _ ->
      %{
        banks: %{},
        memory_units: [],
        audit_logs: [],
        documents: %{},
        entities: %{},
        entity_links: %{},
        directives: %{},
        mental_models: %{}
      }
    end)
  end

  def put_memory_unit!(bank_id, attrs) do
    Agent.update(__MODULE__, fn state ->
      unit =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put_new("id", System.unique_integer([:positive]) |> Integer.to_string())
        |> Map.put("bank_id", bank_id)
        |> Map.put_new("context", "chat")
        |> Map.put_new("type", "experience")
        |> Map.put_new("tags", [])
        |> Map.put_new("metadata", %{})
        |> Map.update("source_memory_ids", Map.get(attrs, "source_fact_ids", []), & &1)
        |> Map.put_new("source_memory_ids", [])
        |> Map.put_new("proof_count", 1)

      %{state | memory_units: [unit | state.memory_units]}
    end)
  end

  def put_audit_log!(bank_id, attrs) do
    Agent.update(__MODULE__, fn state ->
      audit_log =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put_new("id", System.unique_integer([:positive]) |> Integer.to_string())
        |> Map.put("bank_id", bank_id)
        |> Map.put_new("action", "retain")
        |> Map.put_new("transport", "backend")
        |> Map.put_new("started_at", DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put_new("ended_at", nil)
        |> Map.put_new("request", %{})
        |> Map.put_new("response", %{})
        |> Map.put_new("metadata", %{})

      %{state | audit_logs: [audit_log | state.audit_logs]}
    end)
  end

  def put_directive!(bank_id, attrs) do
    Agent.update(__MODULE__, fn state ->
      directive = %{
        "id" => Map.get(attrs, "id", System.unique_integer([:positive]) |> Integer.to_string()),
        "bank_id" => bank_id,
        "name" => Map.fetch!(attrs, "name"),
        "content" => Map.fetch!(attrs, "content"),
        "priority" => Map.get(attrs, "priority", 0),
        "is_active" => Map.get(attrs, "is_active", true),
        "tags" => Map.get(attrs, "tags", [])
      }

      key = {bank_id, directive["id"]}
      %{state | directives: Map.put(state.directives, key, directive)}
    end)
  end

  @impl true
  def retain(ctx, %{"async" => true} = payload, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.enqueue_retain(ctx, payload, opts)
  end

  def retain(ctx, %{"items" => items}, opts) do
    embedder = Keyword.fetch!(opts, :embedder)
    extracted_items = extract_retain_items(items)

    with :ok <- validate_retain_item_sizes(items),
         {:ok, dim} <- embedder.dimension([]),
         :ok <- ensure_nonempty_retain_extraction(extracted_items) do
      Agent.get_and_update(__MODULE__, fn state ->
        bank = Map.get(state.banks, ctx.bank, default_bank(ctx.bank))

        units =
          Enum.map(extracted_items, fn item ->
            {:ok, embedding} = embedder.embed(item["content"], [])

            %{
              "id" => System.unique_integer([:positive]) |> Integer.to_string(),
              "bank_id" => ctx.bank,
              "content" => item["content"],
              "context" => item["context"],
              "type" => item["type"] || "experience",
              "tags" => item["tags"] || [],
              "metadata" => item["metadata"] || %{},
              "document_ref" => document_ref(item),
              "source_location" => item["source_location"],
              "source_memory_ids" => normalize_source_memory_ids(item),
              "embedding" => embedding,
              "embedded_dim" => dim,
              "observation_scopes" => normalize_observation_scopes(item),
              "mentioned_at" =>
                item["mentioned_at"] || DateTime.utc_now() |> DateTime.to_iso8601(),
              # Same fallbacks as Storage.Ecto's build_memory_unit_attrs.
              "occurred_at" => item["occurred_at"],
              "occurred_start" => item["occurred_start"] || item["occurred_at"],
              "occurred_end" => item["occurred_end"] || item["occurred_at"]
            }
          end)

        documents = merge_documents(state.documents, ctx.bank, extracted_items)

        new_state = %{
          state
          | banks: Map.put(state.banks, ctx.bank, bank),
            memory_units: state.memory_units ++ units,
            documents: documents
        }

        new_state = attach_entities(new_state, ctx.bank, units)

        if bank["auto_consolidate"] do
          queue = Keyword.fetch!(opts, :queue)

          scopes =
            extracted_items
            |> Enum.map(&scope_key_for_item/1)
            |> Enum.uniq()
            |> Enum.map(&%{"scope_key" => &1})

          _ = queue.enqueue_consolidate(ctx, %{"tag_scopes" => scopes}, opts)
        end

        response = %{
          "success" => true,
          "bank_id" => ctx.bank,
          "items_count" => length(units),
          "async" => false,
          "usage" => nil,
          "extraction" => %{
            "enabled" => false,
            "mode" => nil,
            "fallback_items" => 0,
            "empty_items" => 0
          }
        }

        {response, new_state}
      end)
      |> then(&{:ok, &1})
    end
  end

  def retain(_ctx, _payload, _opts) do
    {:error, Error.new(:invalid_request, %{message: "retain payload must include an items list"})}
  end

  @impl true
  def recall(ctx, %{"query" => query} = payload, opts) do
    case Enum.find(@unsupported_recall_fields, &Map.has_key?(payload, &1)) do
      nil ->
        with :ok <- validate_tag_filters(payload),
             :ok <- validate_query_timestamp(payload["query_timestamp"]) do
          types = Map.get(payload, "types")
          max_tokens = Map.get(payload, "max_tokens", 4096)
          question_date = parse_query_timestamp(payload["query_timestamp"])
          temporal_constraint = temporal_constraint(query, payload["query_timestamp"])

          reranker = Keyword.fetch!(opts, :reranker)

          {candidates, strategy_trace, strategy_items, fused_strategy_items} =
            Agent.get(__MODULE__, fn state ->
              base_units =
                Enum.filter(state.memory_units, fn unit ->
                  unit["bank_id"] == ctx.bank and
                    (not Map.get(payload, "source_linked_only", false) or
                       List.wrap(unit["source_fact_ids"] || unit["source_memory_ids"]) != []) and
                    (is_nil(types) or unit_type_allowed?(unit, types))
                end)

              semantic_candidates =
                base_units
                |> Enum.filter(&semantic_match?(&1, query))
                |> Enum.map(&put_strategy_score(&1, "semantic", fake_score(&1, query)))
                |> Enum.take(semantic_fetch_limit(payload))

              semantic_units =
                semantic_candidates
                |> Enum.filter(
                  &(Map.get(&1, "semantic_score", 0.0) >= @semantic_similarity_floor)
                )
                |> select_semantic_candidates(payload)

              keyword_units =
                base_units
                |> Enum.filter(&keyword_match?(&1, query))
                |> Enum.map(&put_strategy_score(&1, "keyword", keyword_score(&1, query)))
                |> Enum.take(recall_budget(payload))

              keyword_candidates =
                base_units
                |> Enum.filter(&keyword_match?(&1, query))
                |> Enum.map(&put_strategy_score(&1, "keyword", keyword_score(&1, query)))

              {graph_units, graph_diagnostics} =
                graph_recall_units(base_units, query, payload)

              {temporal_units, temporal_diagnostics} =
                temporal_recall_units(
                  base_units,
                  temporal_constraint,
                  payload["query_timestamp"],
                  query,
                  payload
                )

              strategy_items =
                %{
                  "semantic" =>
                    semantic_units
                    |> Enum.filter(&match_recall_tags?(&1["tags"], payload))
                    |> Enum.filter(&match_query_timestamp?(&1, question_date)),
                  "keyword" =>
                    keyword_units
                    |> Enum.filter(&match_recall_tags?(&1["tags"], payload))
                    |> Enum.filter(&match_query_timestamp?(&1, question_date)),
                  "graph" =>
                    graph_units
                    |> Enum.filter(&match_recall_tags?(&1["tags"], payload))
                    |> Enum.filter(&match_query_timestamp?(&1, question_date)),
                  "temporal" =>
                    temporal_units
                    |> Enum.filter(&match_recall_tags?(&1["tags"], payload))
                    |> Enum.filter(&match_query_timestamp?(&1, question_date))
                }

              strategy_filter_reason_counts = %{
                "semantic" => filter_reason_counts(semantic_units, payload, question_date),
                "keyword" => filter_reason_counts(keyword_units, payload, question_date),
                "graph" => filter_reason_counts(graph_units, payload, question_date),
                "temporal" => filter_reason_counts(temporal_units, payload, question_date)
              }

              strategy_filtered_out_records = %{
                "semantic" => filter_out_records(semantic_units, payload, question_date),
                "keyword" => filter_out_records(keyword_units, payload, question_date),
                "graph" => filter_out_records(graph_units, payload, question_date),
                "temporal" => filter_out_records(temporal_units, payload, question_date)
              }

              strategy_trace =
                %{
                  "semantic" =>
                    strategy_trace(
                      "semantic",
                      true,
                      semantic_units,
                      strategy_items["semantic"],
                      strategy_filter_reason_counts["semantic"],
                      strategy_filtered_out_records["semantic"],
                      %{
                        "gated_out" => [],
                        "capped_out" =>
                          semantic_candidates
                          |> Enum.filter(
                            &(Map.get(&1, "semantic_score", 0.0) >= @semantic_similarity_floor)
                          )
                          |> reject_selected_semantic_candidates(semantic_units)
                          |> Enum.take(5)
                          |> Enum.map(
                            &gate_record(&1, "semantic_score", "semantic_candidate_cap")
                          )
                      }
                    ),
                  "keyword" =>
                    strategy_trace(
                      "keyword",
                      true,
                      keyword_units,
                      strategy_items["keyword"],
                      strategy_filter_reason_counts["keyword"],
                      strategy_filtered_out_records["keyword"],
                      %{
                        "gated_out" => [],
                        "capped_out" =>
                          keyword_candidates
                          |> Enum.drop(recall_budget(payload))
                          |> Enum.take(5)
                          |> Enum.map(&gate_record(&1, "keyword_score", "keyword_candidate_cap"))
                      }
                    ),
                  "graph" =>
                    strategy_trace(
                      "graph",
                      EntityExtractor.extract(query) != [] or source_expansion_mode?(payload),
                      graph_units,
                      strategy_items["graph"],
                      strategy_filter_reason_counts["graph"],
                      strategy_filtered_out_records["graph"],
                      graph_diagnostics
                    )
                    |> maybe_put_strategy_mode(%{
                      source_expansion: source_expansion_mode?(payload)
                    }),
                  "temporal" =>
                    strategy_trace(
                      "temporal",
                      not is_nil(temporal_constraint),
                      temporal_units,
                      strategy_items["temporal"],
                      strategy_filter_reason_counts["temporal"],
                      strategy_filtered_out_records["temporal"],
                      temporal_diagnostics
                    )
                }
                |> Map.new(fn {name, trace} ->
                  {name,
                   trace
                   |> maybe_put_fully_gated_diagnostics(payload["query"] || "")
                   |> maybe_put_empty_diagnostics(payload["query"] || "")}
                end)

              fused_strategy_items =
                maybe_add_source_expansion_fusion_strategy(strategy_items)

              candidates =
                fused_strategy_items
                |> Foresight.Recall.RRF.fuse(k: 60)
                |> Enum.map(fn item ->
                  item
                  # Mirror production (storage/ecto.ex): under a calibrated fusion mode the
                  # authoritative score is fused_score; only :rrf falls back to rrf_score.
                  |> Map.put("score", item["fused_score"] || item["rrf_score"])
                  |> Map.put("fusion", %{
                    "rrf_score" => item["rrf_score"],
                    "strategy_contributions" => item["strategy_contributions"]
                  })
                end)

              {candidates, strategy_trace, strategy_items, fused_strategy_items}
            end)

          rerank_candidates = prefilter_rerank_candidates(candidates, payload)
          {:ok, reranked_units} = reranker.rerank(query, rerank_candidates, opts)
          boosted_units = boost_recall_items(reranked_units, payload)
          min_score = Map.get(payload, "min_score")

          units =
            boosted_units
            |> Enum.filter(&(is_nil(min_score) or (&1["score"] || 0.0) >= min_score))
            |> trim_units_to_token_budget(max_tokens)

          include_chunks = get_in(payload, ["include", "chunks"]) != nil
          include_source_facts = get_in(payload, ["include", "source_facts"]) != nil
          include_candidate_pool = candidate_pool_requested?(payload)

          include_entities =
            get_in(payload, ["include", "entities"]) != nil or !Map.has_key?(payload, "include")

          results =
            Enum.map(units, fn unit ->
              entities = Foresight.EntityExtractors.Simple.extract(unit["content"])

              %{
                "id" => unit["id"],
                "text" => unit["content"],
                "type" => unit["type"],
                "score" => unit["score"],
                "entities" => entities,
                "context" => unit["context"],
                "occurred_start" => unit["occurred_start"] || unit["mentioned_at"],
                "occurred_end" => unit["occurred_end"] || unit["mentioned_at"],
                "mentioned_at" => unit["mentioned_at"],
                "document_id" => unit["document_ref"],
                "source_location" => unit["source_location"],
                "metadata" => unit["metadata"],
                "chunk_id" => if(include_chunks, do: unit["id"], else: nil),
                "tags" => unit["tags"],
                "source_fact_ids" => unit["source_memory_ids"] || []
              }
            end)

          response =
            %{
              "results" => results,
              "trace" =>
                if(payload["trace"],
                  do:
                    recall_trace(
                      query,
                      payload,
                      results,
                      strategy_trace,
                      strategy_items,
                      candidates,
                      rerank_candidates,
                      reranked_units,
                      boosted_units,
                      units
                    )
                ),
              "entities" => if(include_entities, do: fake_entity_states(results), else: nil),
              "chunks" => if(include_chunks, do: fake_chunks(results), else: nil),
              "source_facts" => if(include_source_facts, do: %{}, else: nil)
            }

          {:ok,
           if include_candidate_pool do
             Map.put(
               response,
               "candidate_pool",
               CandidatePool.pool(fused_strategy_items, candidate_pool_opts(payload))
             )
           else
             response
           end}
        end

      key ->
        {:error,
         Error.new(:invalid_request, %{
           message: "#{key} is not part of hindsight's recall contract"
         })}
    end
  end

  def recall(_ctx, _payload, _opts) do
    {:error,
     Error.new(:invalid_request, %{message: "recall payload must include a query string"})}
  end

  defp candidate_pool_opts(payload) do
    case get_in(payload, ["include", "candidate_pool"]) do
      %{"top_k" => top_k} when is_integer(top_k) and top_k > 0 -> [top_k: top_k]
      _other -> []
    end
  end

  defp candidate_pool_requested?(payload) do
    case get_in(payload, ["include", "candidate_pool"]) do
      true -> true
      %{} -> true
      _other -> false
    end
  end

  @impl true
  def reflect(ctx, %{"query" => query} = payload, opts) do
    timeout_ms = Keyword.get(opts, :reflect_timeout_ms, 120_000)

    task =
      Task.async(fn ->
        reflect_once(ctx, query, payload, opts)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)

        {:error,
         Error.new(:timeout, %{
           message: "reflect timed out after #{timeout_ms}ms"
         })}
    end
  end

  def reflect(_ctx, _payload, _opts) do
    {:error,
     Error.new(:invalid_request, %{message: "reflect payload must include a query string"})}
  end

  defp reflect_once(ctx, query, payload, opts) do
    llm = Keyword.fetch!(opts, :llm)
    started_at_ms = monotonic_ms()
    observations = reflect_observations(ctx, payload)
    max_iterations = reflect_max_iterations(payload, opts)

    with {{:ok, recall_result}, recall_ms} <- timed_ms(fn -> recall(ctx, payload, opts) end),
         {:ok, bank_profile} <- bank_profile(ctx, ctx.bank, opts),
         directives <- active_directives(ctx.bank, payload),
         mental_models <- active_mental_models(ctx.bank, payload),
         initial_plan_prompt =
           Foresight.Prompts.Reflect.Plan.V1.build(
             query,
             payload,
             bank_profile,
             recall_result["results"],
             observations,
             directives,
             mental_models
           ),
         {{:ok, plan}, planner_ms} <-
           timed_ms(fn ->
             llm.complete_structured(
               initial_plan_prompt,
               [],
               Foresight.Prompts.ReflectPlanResponse,
               []
             )
           end),
         {{:ok, loop_state}, loop_ms} <-
           timed_ms(fn ->
             run_reflect_loop(
               ctx,
               payload,
               opts,
               llm,
               bank_profile,
               directives,
               recall_result,
               mental_models,
               plan,
               initial_plan_prompt,
               observations,
               max_iterations
             )
           end),
         {{:ok, loop_state}, evidence_replan_ms} <-
           timed_ms(fn ->
             maybe_replan_for_evidence_breadth(
               {:ok, loop_state},
               ctx,
               payload,
               opts,
               llm,
               bank_profile,
               directives,
               max_iterations
             )
           end) do
      phase_timings = %{
        "recall_ms" => recall_ms,
        "planner_ms" => planner_ms,
        "loop_ms" => loop_ms,
        "evidence_replan_ms" => evidence_replan_ms
      }

      if no_grounded_evidence?(loop_state) do
        final_text = no_evidence_reflect_text()

        with {{:ok, structured_output}, structured_output_ms} <-
               timed_ms(fn ->
                 maybe_structured_reflect_output(llm, query, final_text, payload)
               end) do
          llm_calls =
            estimate_plan_llm_calls(loop_state.plan_events) ++
              maybe_structured_llm_trace(payload, query, final_text, structured_output)

          {:ok,
           %{
             "text" => final_text,
             "based_on" => %{
               "memories" => [],
               "mental_models" => [],
               "directives" => directives
             },
             "structured_output" => structured_output,
             "usage" => usage_from_llm_calls(llm_calls),
             "trace" => %{
               "tool_calls" => reflect_tool_calls(loop_state.tool_calls, payload),
               "llm_calls" => llm_calls,
               "directives_applied" => Enum.map(directives, & &1["name"]),
               "directive_compliance" => %{
                 "status" => "not_applicable",
                 "notes" => "no grounded evidence available"
               },
               "mental_models_considered" => [],
               "grounding_validation" => %{
                 "used_memory_ids" => [],
                 "used_mental_model_ids" => [],
                 "used_observation_ids" => [],
                 "rejected_memory_ids" => [],
                 "rejected_mental_model_ids" => [],
                 "rejected_observation_ids" => []
               },
               "budget" => to_string(Map.get(payload, "budget", "low")),
               "max_iterations" => max_iterations,
               "termination" => loop_state.termination,
               "timings_ms" =>
                 phase_timings
                 |> Map.put("structured_output_ms", structured_output_ms)
                 |> Map.put("total_ms", monotonic_ms() - started_at_ms),
               "observations" => Map.drop(loop_state.observations, ["observations"]),
               "no_evidence_fallback" => true
             }
           }}
        end
      else
        reflect_synthesize(
          llm,
          query,
          payload,
          opts,
          bank_profile,
          directives,
          loop_state,
          max_iterations,
          phase_timings,
          started_at_ms
        )
      end
    end
  end

  defp reflect_synthesize(
         llm,
         query,
         payload,
         opts,
         bank_profile,
         directives,
         loop_state,
         max_iterations,
         phase_timings,
         started_at_ms
       ) do
    plan = loop_state.current_plan

    loop_context = %{
      reason: plan.reason,
      answer_ready: plan.answer_ready,
      needs_consolidation: plan.needs_consolidation,
      max_iterations: max_iterations
    }

    {{reflect_prompt, context_guard}, prompt_fit_ms} =
      timed_ms(fn ->
        fit_reflect_prompt_context(
          llm,
          query,
          payload,
          bank_profile,
          loop_state.recall_result["results"],
          loop_state.observations,
          directives,
          loop_state.mental_models,
          loop_context,
          opts
        )
      end)

    with {{:ok,
           %Foresight.Prompts.ReflectResponse{
             text: text,
             directive_compliance: directive_compliance,
             memory_ids: memory_ids,
             mental_model_ids: mental_model_ids,
             observation_ids: observation_ids
           }}, synthesize_ms} <-
           timed_ms(fn ->
             llm.complete_structured(
               reflect_prompt,
               [],
               Foresight.Prompts.ReflectResponse,
               []
             )
           end),
         cleaned_text = clean_reflect_answer_text(text),
         {{:ok, rewritten_text, rewrite_trace}, rewrite_ms} <-
           timed_ms(fn ->
             maybe_rewrite_reflect_text(llm, query, cleaned_text, payload)
           end),
         final_text = clean_reflect_answer_text(rewritten_text),
         grounded_memory_ids = List.wrap(memory_ids),
         grounding_validation =
           validate_reflect_grounding_ids(
             loop_state.grounded_results,
             loop_state.mental_models,
             grounded_memory_ids,
             mental_model_ids,
             observation_ids
           ),
         evidence_discipline =
           reflect_evidence_discipline(
             loop_state,
             grounding_validation,
             directive_compliance,
             opts
           ),
         disciplined_text =
           evidence_discipline_text(final_text, evidence_discipline),
         disciplined_directive_compliance =
           evidence_discipline_directive_compliance(directive_compliance, evidence_discipline),
         {{:ok, structured_output}, structured_output_ms} <-
           timed_ms(fn ->
             maybe_structured_reflect_output(llm, query, disciplined_text, payload)
           end) do
      llm_calls =
        estimate_plan_llm_calls(loop_state.plan_events) ++
          [
            estimate_llm_call(
              "synthesize",
              "reflect.v1",
              reflect_prompt,
              %{
                "text" => disciplined_text,
                "directive_compliance" => disciplined_directive_compliance,
                "memory_ids" => grounded_memory_ids,
                "mental_model_ids" => mental_model_ids,
                "observation_ids" => observation_ids
              }
            )
          ] ++
          rewrite_trace ++
          maybe_structured_llm_trace(payload, query, disciplined_text, structured_output)

      reflect_branch =
        reflect_branch_summary(
          loop_state.tool_calls,
          loop_state.termination,
          loop_state.plan_events,
          max_iterations
        )

      reflect_overview =
        reflect_overview_summary(
          reflect_branch,
          loop_state.termination,
          loop_state.plan_events,
          max_iterations
        )

      {:ok,
       %{
         "text" => disciplined_text,
         "memory_ids" => grounding_validation["used_memory_ids"],
         "mental_model_ids" => grounding_validation["used_mental_model_ids"],
         "observation_ids" => grounding_validation["used_observation_ids"],
         "based_on" => %{
           "memories" =>
             loop_state.grounded_results
             |> filter_grounded_memories(grounding_validation)
             |> Enum.map(&based_on_memory/1),
           "mental_models" =>
             loop_state.mental_models
             |> filter_grounded_mental_models(grounding_validation),
           "directives" => directives
         },
         "structured_output" => structured_output,
         "usage" => usage_from_llm_calls(llm_calls),
         "trace" => %{
           "tool_calls" => reflect_tool_calls(loop_state.tool_calls, payload),
           "llm_calls" => llm_calls,
           "directives_applied" => Enum.map(directives, & &1["name"]),
           "directive_compliance" => disciplined_directive_compliance,
           "mental_models_considered" => Enum.map(loop_state.mental_models, & &1["id"]),
           "grounding_validation" => grounding_validation,
           "evidence_discipline" => evidence_discipline,
           "reflect_branch" => reflect_branch,
           "reflect_overview" => reflect_overview,
           "budget" => to_string(Map.get(payload, "budget", "low")),
           "max_iterations" => max_iterations,
           "termination" => loop_state.termination,
           "timings_ms" =>
             phase_timings
             |> Map.put("prompt_fit_ms", prompt_fit_ms)
             |> Map.put("synthesize_ms", synthesize_ms)
             |> Map.put("rewrite_ms", rewrite_ms)
             |> Map.put("structured_output_ms", structured_output_ms)
             |> Map.put("total_ms", monotonic_ms() - started_at_ms),
           "observations" => Map.drop(loop_state.observations, ["observations"]),
           "context_guard" => context_guard
         }
       }}
    end
  end

  defp fit_reflect_prompt_context(
         llm,
         query,
         payload,
         bank_profile,
         recalled_results,
         observations,
         directives,
         mental_models,
         loop_context,
         opts
       ) do
    prompt =
      Foresight.Prompts.Reflect.V1.build(
        query,
        payload,
        bank_profile,
        recalled_results,
        observations,
        directives,
        mental_models,
        loop_context
      )

    max_context_tokens = effective_reflect_max_context_tokens(llm, opts)

    with true <- is_integer(max_context_tokens) and max_context_tokens > 0,
         {:ok, original_tokens} <- reflect_prompt_token_count(prompt),
         true <- original_tokens > max_context_tokens do
      compact_recalled =
        Enum.map(recalled_results, fn result -> Map.delete(result, "expanded_context") end)

      compact_prompt =
        Foresight.Prompts.Reflect.V1.build(
          query,
          payload,
          bank_profile,
          compact_recalled,
          observations,
          directives,
          mental_models,
          loop_context
        )

      case reflect_prompt_token_count(compact_prompt) do
        {:ok, compact_tokens} when compact_tokens <= max_context_tokens ->
          {compact_prompt,
           %{
             "activated" => true,
             "max_context_tokens" => max_context_tokens,
             "original_tokens" => original_tokens,
             "final_tokens" => compact_tokens,
             "dropped_expanded_context" => true,
             "omitted_recalled_count" => 0,
             "omitted_mental_model_count" => 0
           }}

        _ ->
          fitted =
            fit_prompt_evidence(
              query,
              payload,
              bank_profile,
              compact_recalled,
              observations,
              directives,
              mental_models,
              loop_context,
              max_context_tokens
            )

          fitted_prompt =
            Foresight.Prompts.Reflect.V1.build(
              query,
              payload,
              bank_profile,
              fitted.recalled,
              observations,
              directives,
              fitted.mental_models,
              loop_context
            )

          {fitted_prompt,
           %{
             "activated" => true,
             "max_context_tokens" => max_context_tokens,
             "original_tokens" => original_tokens,
             "final_tokens" => fitted.final_tokens,
             "dropped_expanded_context" => true,
             "omitted_recalled_count" => length(compact_recalled) - length(fitted.recalled),
             "omitted_mental_model_count" => length(mental_models) - length(fitted.mental_models)
           }}
      end
    else
      _ ->
        {prompt,
         %{
           "activated" => false,
           "max_context_tokens" => max_context_tokens
         }}
    end
  end

  defp fit_prompt_evidence(
         query,
         payload,
         bank_profile,
         recalled_results,
         observations,
         directives,
         mental_models,
         loop_context,
         max_context_tokens
       ) do
    fit_prompt =
      fn recalled, fitted_mental_models ->
        Foresight.Prompts.Reflect.V1.build(
          query,
          payload,
          bank_profile,
          recalled,
          observations,
          directives,
          fitted_mental_models,
          loop_context
        )
      end

    {fitted_mental_models, _} =
      Enum.reduce_while(mental_models, {[], nil}, fn mental_model, {acc, _tokens} ->
        candidate = acc ++ [mental_model]

        case reflect_prompt_token_count(fit_prompt.([], candidate)) do
          {:ok, tokens} when tokens <= max_context_tokens -> {:cont, {candidate, tokens}}
          _ -> {:halt, {acc, nil}}
        end
      end)

    {fitted_recalled, final_tokens} =
      Enum.reduce_while(recalled_results, {[], nil}, fn result, {acc, _tokens} ->
        candidate = acc ++ [result]

        case reflect_prompt_token_count(fit_prompt.(candidate, fitted_mental_models)) do
          {:ok, tokens} when tokens <= max_context_tokens -> {:cont, {candidate, tokens}}
          _ -> {:halt, {acc, nil}}
        end
      end)

    final_tokens =
      final_tokens ||
        case reflect_prompt_token_count(fit_prompt.(fitted_recalled, fitted_mental_models)) do
          {:ok, tokens} -> tokens
          _ -> 0
        end

    %{
      recalled: fitted_recalled,
      mental_models: fitted_mental_models,
      final_tokens: final_tokens
    }
  end

  defp effective_reflect_max_context_tokens(llm, opts) do
    configured_max_context = Keyword.get(opts, :reflect_max_context_tokens, 100_000)
    llm_max_context = llm_max_context_tokens(llm, opts)

    cond do
      positive_integer?(configured_max_context) and positive_integer?(llm_max_context) ->
        min(configured_max_context, llm_max_context)

      positive_integer?(configured_max_context) ->
        configured_max_context

      positive_integer?(llm_max_context) ->
        llm_max_context

      true ->
        100_000
    end
  end

  defp llm_max_context_tokens(llm, opts) when is_atom(llm) do
    cond do
      function_exported?(llm, :prompt_budget_tokens, 1) -> llm.prompt_budget_tokens(opts)
      function_exported?(llm, :max_context_tokens, 1) -> llm.max_context_tokens(opts)
      true -> nil
    end
  end

  defp llm_max_context_tokens(_llm, _opts), do: nil

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp reflect_prompt_token_count(prompt) do
    prompt
    |> Foresight.Prompts.Reflect.V1.messages()
    |> Enum.map_join("\n\n", &to_string(Map.get(&1, :content) || Map.get(&1, "content") || ""))
    |> Budget.count_tokens()
  end

  @impl true
  def consolidate(ctx, %{"async" => true} = payload, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.enqueue_consolidate(ctx, payload, opts)
  end

  def consolidate(ctx, payload, _opts) when is_map(payload) do
    Agent.get_and_update(__MODULE__, fn state ->
      requested_scopes = requested_scopes(payload)

      scoped_units =
        state.memory_units
        |> Enum.filter(&(&1["bank_id"] == ctx.bank and &1["type"] in ["world", "experience"]))
        |> Enum.group_by(&scope_key_for_unit/1)
        |> Enum.filter(fn {scope, _units} ->
          requested_scopes == [] or scope in requested_scopes
        end)

      {memory_units, mental_models} =
        Enum.reduce(scoped_units, {state.memory_units, state.mental_models}, fn {scope, units},
                                                                                {units_acc,
                                                                                 models_acc} ->
          observation = observation_for_scope(ctx.bank, scope, units)

          units_acc =
            units_acc
            |> Enum.reject(fn unit ->
              unit["bank_id"] == ctx.bank and unit["type"] == "observation" and
                unit["source_memory_ids"] == observation["source_memory_ids"]
            end)
            |> Kernel.++([observation])

          mental_model = mental_model_for_scope(ctx.bank, scope, observation)
          {units_acc, Map.put(models_acc, {ctx.bank, mental_model["id"]}, mental_model)}
        end)

      response = %{
        "success" => true,
        "bank_id" => ctx.bank,
        "observations_created" => length(scoped_units),
        "scopes_consolidated" => length(scoped_units),
        "operation" => "consolidate"
      }

      {response, %{state | memory_units: memory_units, mental_models: mental_models}}
    end)
    |> then(&{:ok, &1})
  end

  @impl true
  def list_banks(_ctx, _opts) do
    banks =
      Agent.get(__MODULE__, fn state ->
        state.banks
        |> Map.values()
        |> Enum.sort_by(& &1["id"])
        |> Enum.map(fn bank ->
          Map.merge(bank, %{
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "fact_count" => 0
          })
        end)
      end)

    {:ok, banks}
  end

  @impl true
  def put_bank(_ctx, bank_id, attrs, _opts) do
    bank = %{
      "id" => bank_id,
      "bank_id" => bank_id,
      "name" => Map.get(attrs, "name", bank_id),
      "mission" => Map.get(attrs, "mission", ""),
      "disposition" => Map.get(attrs, "disposition", %{}),
      "auto_consolidate" => Map.get(attrs, "auto_consolidate", false)
    }

    Agent.update(__MODULE__, fn state ->
      %{state | banks: Map.put(state.banks, bank_id, bank)}
    end)

    {:ok, bank}
  end

  @impl true
  def patch_bank(_ctx, bank_id, attrs, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.banks, bank_id) do
        :error ->
          {{:error, Foresight.Error.new(:not_found, %{message: "bank not found"})}, state}

        {:ok, bank} ->
          patched =
            bank
            |> maybe_put_bank_field("name", Map.get(attrs, "name"))
            |> maybe_put_bank_field("mission", Map.get(attrs, "mission"))
            |> maybe_put_bank_field("background", Map.get(attrs, "background"))
            |> maybe_put_bank_field("disposition", Map.get(attrs, "disposition"))
            |> maybe_put_bank_field("auto_consolidate", Map.get(attrs, "auto_consolidate"))

          {{:ok, patched}, %{state | banks: Map.put(state.banks, bank_id, patched)}}
      end
    end)
  end

  @impl true
  def update_bank_disposition(ctx, bank_id, disposition, opts) do
    patch_bank(ctx, bank_id, %{"disposition" => disposition}, opts)
  end

  @impl true
  def add_bank_background(_ctx, bank_id, content, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.banks, bank_id) do
        :error ->
          {{:error, Foresight.Error.new(:not_found, %{message: "bank not found"})}, state}

        {:ok, bank} ->
          current = String.trim(bank["mission"] || "")

          mission =
            cond do
              current == "" -> content
              String.contains?(current, content) -> current
              true -> current <> " " <> content
            end

          patched =
            bank
            |> Map.put("mission", mission)
            |> Map.put("background", mission)

          response = %{"mission" => mission, "background" => mission}
          {{:ok, response}, %{state | banks: Map.put(state.banks, bank_id, patched)}}
      end
    end)
  end

  @impl true
  def delete_bank(_ctx, bank_id, _opts) do
    Agent.update(__MODULE__, fn state ->
      %{
        state
        | banks: Map.delete(state.banks, bank_id),
          memory_units: Enum.reject(state.memory_units, &(&1["bank_id"] == bank_id)),
          documents:
            state.documents
            |> Enum.reject(fn {{doc_bank_id, _doc_id}, _document} -> doc_bank_id == bank_id end)
            |> Map.new(),
          mental_models:
            state.mental_models
            |> Enum.reject(fn {{doc_bank_id, _doc_id}, _document} -> doc_bank_id == bank_id end)
            |> Map.new()
      }
    end)

    {:ok, %{"id" => bank_id, "deleted" => true, "deleted_count" => 0}}
  end

  @impl true
  def clear_bank_memories(_ctx, bank_id, params, _opts) do
    type = Map.get(params, "type")

    Agent.update(__MODULE__, fn state ->
      filtered_units =
        Enum.reject(state.memory_units, fn unit ->
          unit["bank_id"] == bank_id and (is_nil(type) or unit["type"] == type)
        end)

      %{state | memory_units: filtered_units}
    end)

    {:ok, %{"id" => bank_id, "deleted" => true}}
  end

  @impl true
  def delete_memory(ctx, _bank_id, memory_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Enum.find(state.memory_units, &(&1["bank_id"] == ctx.bank and &1["id"] == memory_id)) do
        nil ->
          {{:error, Error.new(:not_found, %{message: "memory not found"})}, state}

        _unit ->
          {deleted, kept} =
            Enum.split_with(state.memory_units, fn unit ->
              unit["bank_id"] == ctx.bank and
                (unit["id"] == memory_id or memory_id in List.wrap(unit["source_memory_ids"]))
            end)

          response = %{
            "success" => true,
            "memory_id" => memory_id,
            "memory_units_deleted" => length(deleted),
            "observations_deleted" => length(deleted) - 1
          }

          {{:ok, response}, %{state | memory_units: kept}}
      end
    end)
  end

  @impl true
  def get_bank_config(_ctx, bank_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.banks, bank_id)) do
      nil ->
        {:error, Foresight.Error.new(:not_found, %{message: "bank not found"})}

      bank ->
        {:ok,
         %{
           "bank_id" => bank_id,
           "config" => %{"recall_max_tokens" => 2048},
           "overrides" => Map.get(bank, "config_overrides", %{})
         }}
    end
  end

  @impl true
  def update_bank_config(ctx, bank_id, updates, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.banks, bank_id) do
        :error ->
          {{:error, Foresight.Error.new(:not_found, %{message: "bank not found"})}, state}

        {:ok, bank} ->
          previous_profile = embedding_profile(bank)

          overrides =
            bank
            |> Map.get("config_overrides", %{})
            |> Map.merge(Enum.reject(updates, fn {_key, value} -> is_nil(value) end) |> Map.new())

          updated_bank = Map.put(bank, "config_overrides", overrides)
          next_profile = embedding_profile(updated_bank)

          if previous_profile != next_profile do
            queue = Keyword.fetch!(opts, :queue)

            _ =
              queue.enqueue_embedding_backfill(
                ctx,
                %{
                  "bank_id" => bank_id,
                  "previous_profile" => previous_profile,
                  "target_profile" => next_profile
                },
                opts
              )
          end

          response = %{
            "bank_id" => bank_id,
            "config" => Map.merge(%{"recall_max_tokens" => 2048}, overrides),
            "overrides" => overrides
          }

          {{:ok, response}, %{state | banks: Map.put(state.banks, bank_id, updated_bank)}}
      end
    end)
  end

  @impl true
  def reset_bank_config(ctx, bank_id, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.banks, bank_id) do
        :error ->
          {{:error, Foresight.Error.new(:not_found, %{message: "bank not found"})}, state}

        {:ok, bank} ->
          previous_profile = embedding_profile(bank)
          updated_bank = Map.put(bank, "config_overrides", %{})
          next_profile = embedding_profile(updated_bank)

          if previous_profile != next_profile do
            queue = Keyword.fetch!(opts, :queue)

            _ =
              queue.enqueue_embedding_backfill(
                ctx,
                %{
                  "bank_id" => bank_id,
                  "previous_profile" => previous_profile,
                  "target_profile" => next_profile
                },
                opts
              )
          end

          response = %{
            "bank_id" => bank_id,
            "config" => %{"recall_max_tokens" => 2048},
            "overrides" => %{}
          }

          {{:ok, response}, %{state | banks: Map.put(state.banks, bank_id, updated_bank)}}
      end
    end)
  end

  @impl true
  def create_webhook(_ctx, bank_id, attrs, _opts) do
    {:ok,
     %{
       "id" => "fake-webhook-1",
       "bank_id" => bank_id,
       "url" => attrs["url"],
       "secret" => nil,
       "event_types" => Map.get(attrs, "event_types", ["consolidation.completed"]),
       "enabled" => Map.get(attrs, "enabled", true),
       "http_config" => Map.get(attrs, "http_config", %{}),
       "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
       "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  @impl true
  def list_webhooks(_ctx, _bank_id, _opts), do: {:ok, []}

  @impl true
  def update_webhook(_ctx, bank_id, webhook_id, attrs, _opts) do
    {:ok,
     %{
       "id" => webhook_id,
       "bank_id" => bank_id,
       "url" => Map.get(attrs, "url", "https://example.test/hook"),
       "secret" => nil,
       "event_types" => Map.get(attrs, "event_types", ["consolidation.completed"]),
       "enabled" => Map.get(attrs, "enabled", true),
       "http_config" => Map.get(attrs, "http_config", %{}),
       "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
       "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  @impl true
  def delete_webhook(_ctx, _bank_id, _webhook_id, _opts), do: {:ok, %{"success" => true}}

  @impl true
  def list_webhook_deliveries(_ctx, _bank_id, _webhook_id, _params, _opts),
    do: {:ok, %{"items" => [], "next_cursor" => nil}}

  @impl true
  def export_bank_template(_ctx, bank_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.banks, bank_id)) do
      nil ->
        {:error, Foresight.Error.new(:not_found, %{message: "bank not found"})}

      bank ->
        {:ok,
         %{
           "version" => "1",
           "bank" => export_bank_config(bank),
           "mental_models" => export_mental_models(bank_id),
           "directives" => export_directives(bank_id)
         }}
    end
  end

  @impl true
  def import_bank_template(_ctx, bank_id, manifest, _opts) do
    dry_run = Map.get(manifest, "dry_run", false)

    with :ok <- validate_template_manifest(manifest) do
      Agent.get_and_update(__MODULE__, fn state ->
        bank = Map.get(state.banks, bank_id, default_bank(bank_id))
        bank_overrides = normalize_bank_template_config(Map.get(manifest, "bank"))
        directives = List.wrap(manifest["directives"])
        mental_models = List.wrap(manifest["mental_models"])

        existing_directive_names =
          state.directives
          |> Enum.filter(fn {{directive_bank_id, _id}, _directive} ->
            directive_bank_id == bank_id
          end)
          |> Enum.map(fn {_key, directive} -> directive["name"] end)
          |> MapSet.new()

        existing_mental_model_ids =
          state.mental_models
          |> Enum.filter(fn {{model_bank_id, _id}, _model} -> model_bank_id == bank_id end)
          |> Enum.map(fn {_key, model} -> model["id"] end)
          |> MapSet.new()

        response = %{
          "bank_id" => bank_id,
          "config_applied" => is_map(manifest["bank"]),
          "mental_models_created" =>
            mental_models
            |> Enum.map(& &1["id"])
            |> Enum.reject(&MapSet.member?(existing_mental_model_ids, &1)),
          "mental_models_updated" =>
            mental_models
            |> Enum.map(& &1["id"])
            |> Enum.filter(&MapSet.member?(existing_mental_model_ids, &1)),
          "directives_created" =>
            directives
            |> Enum.map(& &1["name"])
            |> Enum.reject(&MapSet.member?(existing_directive_names, &1)),
          "directives_updated" =>
            directives
            |> Enum.map(& &1["name"])
            |> Enum.filter(&MapSet.member?(existing_directive_names, &1)),
          "operation_ids" => [],
          "dry_run" => dry_run
        }

        if dry_run do
          {{:ok, response}, state}
        else
          updated_bank =
            bank
            |> Map.put("config_overrides", bank_overrides)
            |> Map.put("name", Map.get(bank, "name", bank_id))

          new_state = %{
            state
            | banks: Map.put(state.banks, bank_id, updated_bank),
              directives: upsert_template_directives(state.directives, bank_id, directives),
              mental_models:
                upsert_template_mental_models(state.mental_models, bank_id, mental_models)
          }

          {{:ok, response}, new_state}
        end
      end)
    end
  end

  @impl true
  def bank_stats(_ctx, bank_id, _opts) do
    total =
      Agent.get(__MODULE__, fn state ->
        Enum.count(state.memory_units, &(&1["bank_id"] == bank_id))
      end)

    total_links =
      Agent.get(__MODULE__, fn state ->
        state.entity_links
        |> Map.values()
        |> Enum.count(&(&1["bank_id"] == bank_id))
      end)

    nodes_by_fact_type =
      Agent.get(__MODULE__, fn state ->
        state.memory_units
        |> Enum.filter(&(&1["bank_id"] == bank_id))
        |> Enum.frequencies_by(& &1["type"])
      end)

    failed_consolidation =
      Agent.get(__MODULE__, fn state ->
        state.memory_units
        |> Enum.count(fn unit ->
          unit["bank_id"] == bank_id and unit["type"] in ["experience", "world"] and
            not is_nil(unit["consolidation_failed_at"])
        end)
      end)

    {:ok,
     %{
       "bank_id" => bank_id,
       "total_nodes" => total,
       "total_links" => total_links,
       "total_documents" =>
         Agent.get(__MODULE__, fn state ->
           (Map.values(state.documents) ++ Map.values(state.mental_models))
           |> Enum.count(&(&1["bank_id"] == bank_id))
         end),
       "nodes_by_fact_type" => nodes_by_fact_type,
       "links_by_link_type" =>
         if(total_links > 0, do: %{"co_occurrence" => total_links}, else: %{}),
       "links_by_fact_type" => %{},
       "links_breakdown" => %{},
       "pending_operations" => 0,
       "failed_operations" => 0,
       "last_consolidated_at" =>
         Agent.get(__MODULE__, fn state ->
           state.memory_units
           |> Enum.filter(&(&1["bank_id"] == bank_id and &1["type"] == "observation"))
           |> Enum.map(& &1["consolidated_at"])
           |> Enum.reject(&is_nil/1)
           |> Enum.sort()
           |> List.last()
         end),
       "pending_consolidation" => pending_consolidation_count(bank_id),
       "failed_consolidation" => failed_consolidation,
       "total_observations" => Map.get(nodes_by_fact_type, "observation", 0)
     }}
  end

  @impl true
  def memories_timeseries(_ctx, bank_id, period, time_field, _opts) do
    config = fake_memories_timeseries_config(period)
    normalized_time_field = fake_normalize_memories_timeseries_time_field(time_field)
    end_bucket = fake_memories_timeseries_anchor(config.trunc)

    buckets =
      for index <- 0..(config.count - 1) do
        bucket_time =
          DateTime.add(end_bucket, -config.step_seconds * (config.count - 1 - index), :second)

        %{
          "time" => DateTime.to_iso8601(bucket_time),
          "world" => 0,
          "experience" => 0,
          "observation" => 0
        }
      end

    by_time = Map.new(buckets, fn bucket -> {bucket["time"], bucket} end)

    hydrated =
      Agent.get(__MODULE__, fn state ->
        Enum.reduce(state.memory_units, by_time, fn unit, acc ->
          if unit["bank_id"] != bank_id do
            acc
          else
            bucket_time =
              unit
              |> fake_memories_timeseries_unit_time(normalized_time_field)
              |> fake_memories_timeseries_truncate(config.trunc)

            key = DateTime.to_iso8601(bucket_time)
            bucket = Map.get(acc, key)

            if is_nil(bucket) do
              acc
            else
              fact_type = unit["type"] || "experience"
              Map.put(acc, key, Map.update(bucket, fact_type, 1, &(&1 + 1)))
            end
          end
        end)
      end)

    {:ok,
     %{
       "bank_id" => bank_id,
       "period" => config.period,
       "trunc" => config.trunc,
       "time_field" => normalized_time_field,
       "buckets" => Enum.map(buckets, fn bucket -> Map.fetch!(hydrated, bucket["time"]) end)
     }}
  end

  @impl true
  def list_memories(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)
    query = Map.get(params, "q")
    type = Map.get(params, "type")
    tags = Map.get(params, "tags")
    tags_match = Map.get(params, "tags_match", "any")
    after_filter = Map.get(params, "after")
    before_filter = Map.get(params, "before")
    min_score = Map.get(params, "min_score", 0.0)

    units =
      Agent.get(__MODULE__, fn state ->
        state.memory_units
        |> Enum.filter(&(&1["bank_id"] == ctx.bank))
        |> Enum.filter(fn unit -> is_nil(type) or unit["type"] == type end)
        |> Enum.filter(fn unit ->
          is_nil(query) or String.contains?(unit["content"], query) or
            String.contains?(unit["context"], query)
        end)
      end)
      |> Enum.filter(&(is_nil(tags) or unit_tags_match?(&1, tags, tags_match)))
      |> maybe_filter_scope_keys(params["scope_keys"])
      |> Enum.filter(&(is_nil(after_filter) or compare_after(&1, after_filter)))
      |> Enum.filter(&(is_nil(before_filter) or compare_before(&1, before_filter)))
      |> Enum.map(&Map.put(&1, "score", fake_score(&1, query || "")))
      |> Enum.filter(&(&1["score"] >= min_score))

    {:ok,
     %{
       "items" => Enum.slice(units, offset, limit),
       "total" => length(units),
       "limit" => limit,
       "offset" => offset
     }}
  end

  @impl true
  def get_memory(ctx, memory_id, _opts) do
    case Agent.get(__MODULE__, fn state ->
           Enum.find(state.memory_units, &(&1["bank_id"] == ctx.bank and &1["id"] == memory_id))
         end) do
      nil ->
        {:error, Error.new(:not_found, %{message: "memory not found"})}

      unit ->
        {:ok,
         %{
           "id" => unit["id"],
           "text" => unit["text"] || unit["content"],
           "content" => unit["content"],
           "context" => unit["context"],
           "type" => unit["type"],
           "tags" => unit["tags"] || [],
           "metadata" => unit["metadata"] || %{},
           "document_id" => unit["document_id"] || unit["document_ref"],
           "mentioned_at" => unit["mentioned_at"],
           "occurred_at" => unit["occurred_at"],
           "occurred_start" => unit["occurred_start"],
           "occurred_end" => unit["occurred_end"],
           "source_fact_ids" => unit["source_fact_ids"] || unit["source_memory_ids"] || [],
           "history" => [],
           "entities" => unit["entities"] || []
         }}
    end
  end

  @impl true
  def get_memory_history(ctx, memory_id, _opts) do
    case Agent.get(__MODULE__, fn state ->
           Enum.find(state.memory_units, &(&1["bank_id"] == ctx.bank and &1["id"] == memory_id))
         end) do
      nil ->
        {:error, Error.new(:not_found, %{message: "memory not found"})}

      %{"type" => "observation"} = unit ->
        {:ok, get_in(unit, ["metadata", "history"]) || []}

      _unit ->
        {:ok, []}
    end
  end

  @impl true
  def list_tags(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)
    pattern = Map.get(params, "q")

    items =
      Agent.get(__MODULE__, fn state ->
        state.memory_units
        |> Enum.filter(&(&1["bank_id"] == ctx.bank))
        |> Enum.flat_map(&List.wrap(&1["tags"]))
        |> Enum.frequencies()
        |> Enum.map(fn {tag, count} -> %{"tag" => tag, "count" => count} end)
      end)
      |> maybe_filter_fake_tag_pattern(pattern)
      |> Enum.sort_by(fn item -> {-item["count"], item["tag"]} end)

    {:ok,
     %{
       "items" => Enum.slice(items, offset, limit),
       "total" => length(items),
       "limit" => limit,
       "offset" => offset
     }}
  end

  @impl true
  def list_directives(_ctx, bank_id, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)
    active_only = Map.get(params, "active_only", true)
    tags = List.wrap(Map.get(params, "tags", []))

    directives =
      Agent.get(__MODULE__, fn state ->
        state.directives
        |> Map.values()
        |> Enum.filter(&(&1["bank_id"] == bank_id))
      end)
      |> maybe_filter_fake_active(active_only)
      |> maybe_filter_fake_tags(tags)
      |> Enum.sort_by(fn directive -> {-directive["priority"], directive["name"]} end)

    {:ok,
     %{
       "items" => Enum.slice(directives, offset, limit),
       "total" => length(directives),
       "limit" => limit,
       "offset" => offset
     }}
  end

  @impl true
  def get_directive(_ctx, bank_id, directive_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.directives, {bank_id, directive_id})) do
      nil -> {:error, Error.new(:not_found, %{message: "directive not found"})}
      directive -> {:ok, directive}
    end
  end

  @impl true
  def create_directive(_ctx, bank_id, attrs, _opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    directive_id = Map.get(attrs, "id", System.unique_integer([:positive]) |> Integer.to_string())

    directive = %{
      "id" => directive_id,
      "bank_id" => bank_id,
      "name" => Map.fetch!(attrs, "name"),
      "content" => Map.fetch!(attrs, "content"),
      "priority" => Map.get(attrs, "priority", 0),
      "is_active" => Map.get(attrs, "is_active", true),
      "tags" => Map.get(attrs, "tags", []),
      "created_at" => now,
      "updated_at" => now
    }

    Agent.update(__MODULE__, fn state ->
      %{state | directives: Map.put(state.directives, {bank_id, directive_id}, directive)}
    end)

    {:ok, directive}
  end

  @impl true
  def update_directive(_ctx, bank_id, directive_id, attrs, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.directives, {bank_id, directive_id}) do
        nil ->
          {{:error, Error.new(:not_found, %{message: "directive not found"})}, state}

        directive ->
          updated =
            directive
            |> Map.merge(Map.take(attrs, ["name", "content", "priority", "is_active", "tags"]))
            |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

          {{:ok, updated},
           %{state | directives: Map.put(state.directives, {bank_id, directive_id}, updated)}}
      end
    end)
  end

  @impl true
  def delete_directive(_ctx, bank_id, directive_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.has_key?(state.directives, {bank_id, directive_id}) do
        true ->
          {{:ok, %{"deleted" => true}},
           %{state | directives: Map.delete(state.directives, {bank_id, directive_id})}}

        false ->
          {{:error, Error.new(:not_found, %{message: "directive not found"})}, state}
      end
    end)
  end

  @impl true
  def list_mental_models(_ctx, bank_id, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)
    detail = Map.get(params, "detail", "full")
    tags = List.wrap(Map.get(params, "tags", []))

    models =
      Agent.get(__MODULE__, fn state ->
        state.mental_models
        |> Map.values()
        |> Enum.filter(&(&1["bank_id"] == bank_id))
      end)
      |> maybe_filter_fake_tags(tags)
      |> Enum.sort_by(& &1["id"])

    items =
      models
      |> Enum.slice(offset, limit)
      |> Enum.map(&fake_mental_model_response(&1, detail))

    {:ok,
     %{
       "items" => items,
       "total" => length(models),
       "limit" => limit,
       "offset" => offset
     }}
  end

  @impl true
  def get_mental_model(_ctx, bank_id, mental_model_id, params, _opts) do
    detail = Map.get(params, "detail", "full")

    case Agent.get(__MODULE__, &Map.get(&1.mental_models, {bank_id, mental_model_id})) do
      nil -> {:error, Error.new(:not_found, %{message: "mental model not found"})}
      model -> {:ok, fake_mental_model_response(model, detail)}
    end
  end

  @impl true
  def get_mental_model_history(_ctx, bank_id, mental_model_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.mental_models, {bank_id, mental_model_id})) do
      nil ->
        {:error, Error.new(:not_found, %{message: "mental model not found"})}

      model ->
        {:ok, get_in(model, ["metadata", "history"]) || []}
    end
  end

  @impl true
  def create_mental_model(ctx, bank_id, attrs, opts) do
    model_id = Map.get(attrs, "id", "mm-generated")
    queue = Keyword.fetch!(opts, :queue)

    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.mental_models, {bank_id, model_id}) do
        nil ->
          model = fake_mental_model_record(bank_id, Map.put(attrs, "id", model_id))

          new_state = %{
            state
            | mental_models: Map.put(state.mental_models, {bank_id, model_id}, model)
          }

          response =
            case queue.enqueue_refresh_mental_model(
                   ctx,
                   %{"bank_id" => bank_id, "mental_model_id" => model_id},
                   opts
                 ) do
              {:ok, result} ->
                {:ok,
                 %{
                   "mental_model_id" => model_id,
                   "operation_id" => result["operation_id"]
                 }}

              {:error, %Error{} = error} ->
                {:error, error}
            end

          {response, new_state}

        _model ->
          {{:error, Error.new(:invalid_request, %{message: "mental model id already exists"})},
           state}
      end
    end)
  end

  def refresh_mental_model_operation(
        _ctx,
        %{"bank_id" => bank_id, "mental_model_id" => model_id},
        _opts
      ) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.mental_models, {bank_id, model_id}) do
        nil ->
          {{:error, Error.new(:not_found, %{message: "mental model not found"})}, state}

        model ->
          refreshed_at = DateTime.utc_now() |> DateTime.to_iso8601()
          metadata = Map.get(model, "metadata", %{})
          history = append_mental_model_history(metadata, model["original_text"])

          reflect_response = %{
            "text" => "Refreshed mental model for #{metadata["source_query"]}",
            "based_on" => %{"memories" => [], "mental_models" => [], "directives" => []}
          }

          updated =
            model
            |> Map.put("original_text", reflect_response["text"])
            |> Map.put(
              "metadata",
              metadata
              |> Map.put("history", history)
              |> Map.put("reflect_response", reflect_response)
              |> Map.put("last_refreshed_at", refreshed_at)
              |> Map.put("is_stale", false)
            )

          result = %{
            "operation" => "refresh_mental_model",
            "bank_id" => bank_id,
            "mental_model_id" => model_id,
            "content_updated" => true,
            "last_refreshed_at" => refreshed_at
          }

          {{:ok, result},
           %{state | mental_models: Map.put(state.mental_models, {bank_id, model_id}, updated)}}
      end
    end)
  end

  @impl true
  def refresh_mental_model(ctx, bank_id, mental_model_id, opts) do
    queue = Keyword.fetch!(opts, :queue)

    case Agent.get(__MODULE__, &Map.get(&1.mental_models, {bank_id, mental_model_id})) do
      nil ->
        {:error, Error.new(:not_found, %{message: "mental model not found"})}

      _model ->
        case queue.enqueue_refresh_mental_model(
               ctx,
               %{"bank_id" => bank_id, "mental_model_id" => mental_model_id},
               opts
             ) do
          {:ok, result} ->
            {:ok, %{"operation_id" => result["operation_id"], "status" => "queued"}}

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  @impl true
  def update_mental_model(_ctx, bank_id, mental_model_id, attrs, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.mental_models, {bank_id, mental_model_id}) do
        nil ->
          {{:error, Error.new(:not_found, %{message: "mental model not found"})}, state}

        model ->
          current_metadata = Map.get(model, "metadata", %{})

          history =
            case Map.fetch(attrs, "content") do
              {:ok, content} ->
                if content != model["original_text"] do
                  append_mental_model_history(current_metadata, model["original_text"])
                else
                  Map.get(current_metadata, "history", [])
                end

              _ ->
                Map.get(current_metadata, "history", [])
            end

          metadata =
            current_metadata
            |> Map.merge(%{
              "source_query" => Map.get(attrs, "source_query", current_metadata["source_query"]),
              "max_tokens" => Map.get(attrs, "max_tokens", current_metadata["max_tokens"]),
              "trigger" => Map.get(attrs, "trigger", current_metadata["trigger"]),
              "history" => history
            })

          original_text =
            case Map.fetch(attrs, "source_query") do
              {:ok, source_query} ->
                "Pending mental model content generation for #{source_query}"

              :error ->
                model["original_text"]
            end

          updated =
            model
            |> Map.put("name", Map.get(attrs, "name", model["name"]))
            |> Map.put("title", Map.get(attrs, "name", model["title"]))
            |> Map.put("tags", Map.get(attrs, "tags", model["tags"]))
            |> Map.put("metadata", metadata)
            |> Map.put("original_text", original_text)

          {{:ok, fake_mental_model_response(updated, "full")},
           %{
             state
             | mental_models: Map.put(state.mental_models, {bank_id, mental_model_id}, updated)
           }}
      end
    end)
  end

  @impl true
  def delete_mental_model(_ctx, bank_id, mental_model_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.has_key?(state.mental_models, {bank_id, mental_model_id}) do
        true ->
          {{:ok, %{"deleted" => true}},
           %{state | mental_models: Map.delete(state.mental_models, {bank_id, mental_model_id})}}

        false ->
          {{:error, Error.new(:not_found, %{message: "mental model not found"})}, state}
      end
    end)
  end

  @impl true
  def list_entities(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)

    entities =
      Agent.get(__MODULE__, fn state ->
        state.entities
        |> Map.values()
        |> Enum.filter(&(&1["bank_id"] == ctx.bank))
        |> Enum.sort_by(fn entity -> {-entity["mention_count"], entity["canonical_name"]} end)
      end)

    {:ok,
     %{
       "items" => Enum.slice(entities, offset, limit),
       "total" => length(entities),
       "limit" => limit,
       "offset" => offset
     }}
  end

  @impl true
  def entity_graph(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)
    min_count = Map.get(params, "min_count", 1)

    {entities, edges} =
      Agent.get(__MODULE__, fn state ->
        entities =
          state.entities
          |> Map.values()
          |> Enum.filter(&(&1["bank_id"] == ctx.bank))

        edges =
          state.entity_links
          |> Map.values()
          |> Enum.filter(fn edge ->
            edge["bank_id"] == ctx.bank and edge["weight"] >= min_count
          end)
          |> Enum.sort_by(fn edge -> {-edge["weight"], edge["id"]} end)
          |> Enum.take(limit)

        {entities, edges}
      end)

    entities_by_id = Map.new(entities, &{&1["id"], &1})

    included_ids =
      Enum.flat_map(edges, &[&1["source_entity_id"], &1["target_entity_id"]]) |> Enum.uniq()

    {:ok,
     %{
       "nodes" =>
         Enum.map(included_ids, fn id ->
           entity = Map.fetch!(entities_by_id, id)

           %{
             "data" => %{
               "id" => id,
               "label" => entity["canonical_name"],
               "mentionCount" => entity["mention_count"],
               "color" => if(entity["mention_count"] > 1, do: "#42a5f5", else: "#90caf9")
             }
           }
         end),
       "edges" =>
         Enum.map(edges, fn edge ->
           %{
             "data" => %{
               "id" => "#{edge["source_entity_id"]}-#{edge["target_entity_id"]}",
               "source" => edge["source_entity_id"],
               "target" => edge["target_entity_id"],
               "linkType" => "cooccurrence",
               "weight" => edge["weight"],
               "color" => "#ffd700",
               "lineStyle" => "solid",
               "lastCooccurred" => edge["updated_at"]
             }
           }
         end),
       "total_entities" => length(included_ids),
       "total_edges" => length(edges),
       "limit" => limit
     }}
  end

  @impl true
  def get_entity(ctx, entity_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.entities, entity_id)) do
      %{"bank_id" => bank_id} = entity when bank_id == ctx.bank ->
        {:ok,
         %{
           "id" => entity["id"],
           "canonical_name" => entity["canonical_name"],
           "mention_count" => entity["mention_count"],
           "first_seen" => entity["first_seen"],
           "last_seen" => entity["last_seen"],
           "metadata" => nil,
           "observations" => []
         }}

      _ ->
        {:error, Error.new(:not_found, %{message: "entity not found"})}
    end
  end

  @impl true
  def bank_profile(_ctx, bank_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.banks, bank_id)) do
      nil ->
        {:error, Error.new(:not_found, %{message: "bank not found"})}

      bank ->
        {:ok,
         %{
           "bank_id" => bank["id"],
           "name" => bank["name"],
           "mission" => bank["mission"],
           "background" => bank["mission"],
           "disposition" => bank["disposition"] || %{},
           "auto_consolidate" => bank["auto_consolidate"] || false
         }}
    end
  end

  @impl true
  def list_documents(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)
    query = Map.get(params, "q")
    tags = Map.get(params, "tags")

    documents =
      Agent.get(__MODULE__, fn state ->
        counts =
          state.memory_units
          |> Enum.filter(&(&1["bank_id"] == ctx.bank))
          |> Enum.frequencies_by(& &1["document_ref"])

        state.documents
        |> Map.values()
        |> Kernel.++(Map.values(state.mental_models))
        |> Enum.filter(&(&1["bank_id"] == ctx.bank))
        |> Enum.map(fn document ->
          Map.put(document, "memory_unit_count", Map.get(counts, document["id"], 0))
        end)
      end)
      |> Enum.filter(fn document ->
        is_nil(query) or String.contains?(document["id"], query) or
          String.contains?(document["title"] || "", query)
      end)
      |> Enum.filter(fn document ->
        is_nil(tags) or Enum.any?(document["tags"], &(&1 in tags))
      end)
      |> Enum.sort_by(& &1["id"])

    {:ok,
     %{
       "items" => Enum.slice(documents, offset, limit),
       "total" => length(documents),
       "limit" => limit,
       "offset" => offset
     }}
  end

  @impl true
  def get_document(ctx, document_id, _opts) do
    document =
      Agent.get(__MODULE__, fn state ->
        state.documents
        |> Map.values()
        |> Enum.find(&(&1["bank_id"] == ctx.bank and &1["id"] == document_id))
      end)

    case document do
      nil ->
        {:error, Error.new(:not_found, %{message: "document not found"})}

      doc ->
        units =
          Agent.get(__MODULE__, fn state ->
            Enum.filter(
              state.memory_units,
              &(&1["bank_id"] == ctx.bank and &1["document_ref"] == doc["id"])
            )
          end)

        {:ok,
         %{
           "id" => doc["id"],
           "bank_id" => doc["bank_id"],
           "original_text" => doc["original_text"] || "",
           "content_hash" => doc["content_hash"],
           "created_at" => doc["created_at"],
           "updated_at" => doc["updated_at"],
           "memory_unit_count" => length(units),
           "nodes_by_fact_type" => Enum.frequencies_by(units, & &1["type"]),
           "tags" => doc["tags"] || [],
           "document_metadata" => doc["metadata"] || %{},
           "retain_params" => nil
         }}
    end
  end

  @impl true
  def list_document_chunks(ctx, document_id, params, _opts) do
    limit = Map.get(params, "limit", 100)
    offset = Map.get(params, "offset", 0)

    case Agent.get(__MODULE__, fn state ->
           Enum.any?(
             Map.values(state.documents),
             &(&1["bank_id"] == ctx.bank and &1["id"] == document_id)
           )
         end) do
      false ->
        {:error, Error.new(:not_found, %{message: "document not found"})}

      true ->
        items =
          Agent.get(__MODULE__, fn state ->
            state.memory_units
            |> Enum.filter(&(&1["bank_id"] == ctx.bank and &1["document_ref"] == document_id))
            |> Enum.sort_by(&{&1["created_at"] || "", &1["id"]})
            |> Enum.with_index()
            |> Enum.map(fn {unit, index} ->
              %{
                "chunk_id" => unit["id"],
                "document_id" => document_id,
                "bank_id" => ctx.bank,
                "chunk_index" => index,
                "chunk_text" => unit["content"],
                "source_location" => unit["source_location"],
                "created_at" => unit["created_at"] || unit["mentioned_at"]
              }
            end)
          end)

        {:ok,
         %{
           "items" => Enum.slice(items, offset, limit),
           "total" => length(items),
           "limit" => limit,
           "offset" => offset
         }}
    end
  end

  @impl true
  def list_audit_logs(ctx, params, _opts) do
    limit = Map.get(params, "limit", 50)
    offset = Map.get(params, "offset", 0)
    action = params["action"]
    transport = params["transport"]
    start_date = normalize_datetime(params["start_date"])
    end_date = normalize_datetime(params["end_date"])

    case Agent.get(__MODULE__, &Map.get(&1.banks, ctx.bank)) do
      nil ->
        {:error, Error.new(:not_found, %{message: "bank not found"})}

      _bank ->
        items =
          Agent.get(__MODULE__, fn state ->
            state.audit_logs
            |> Enum.filter(&(&1["bank_id"] == ctx.bank))
            |> Enum.filter(&(is_nil(action) or &1["action"] == action))
            |> Enum.filter(&(is_nil(transport) or &1["transport"] == transport))
            |> Enum.filter(fn item ->
              dt = normalize_datetime(item["started_at"])
              is_nil(start_date) or (dt && DateTime.compare(dt, start_date) != :lt)
            end)
            |> Enum.filter(fn item ->
              dt = normalize_datetime(item["started_at"])
              is_nil(end_date) or (dt && DateTime.compare(dt, end_date) == :lt)
            end)
            |> Enum.sort_by(fn item -> {item["started_at"] || "", item["id"]} end, :desc)
            |> Enum.map(fn item ->
              %{
                "id" => item["id"],
                "action" => item["action"],
                "transport" => item["transport"],
                "bank_id" => item["bank_id"],
                "started_at" => item["started_at"],
                "ended_at" => item["ended_at"],
                "duration_ms" => fake_audit_log_duration_ms(item),
                "request" => item["request"] || %{},
                "response" => item["response"] || %{},
                "metadata" => item["metadata"] || %{}
              }
            end)
          end)

        {:ok,
         %{
           "bank_id" => ctx.bank,
           "total" => length(items),
           "limit" => limit,
           "offset" => offset,
           "items" => Enum.slice(items, offset, limit)
         }}
    end
  end

  @impl true
  def audit_log_stats(ctx, params, _opts) do
    period = Map.get(params, "period", "7d")
    action = params["action"]
    start = fake_audit_period_start(period)

    case Agent.get(__MODULE__, &Map.get(&1.banks, ctx.bank)) do
      nil ->
        {:error, Error.new(:not_found, %{message: "bank not found"})}

      _bank ->
        buckets =
          Agent.get(__MODULE__, fn state ->
            state.audit_logs
            |> Enum.filter(&(&1["bank_id"] == ctx.bank))
            |> Enum.filter(&(is_nil(action) or &1["action"] == action))
            |> Enum.map(fn item -> {item, normalize_datetime(item["started_at"])} end)
            |> Enum.filter(fn {_item, dt} -> dt && DateTime.compare(dt, start) != :lt end)
            |> Enum.group_by(fn {_item, dt} -> dt |> DateTime.to_date() |> Date.to_iso8601() end)
            |> Enum.sort_by(fn {date, _rows} -> date end)
            |> Enum.map(fn {date, rows} ->
              actions =
                rows
                |> Enum.group_by(fn {item, _dt} -> item["action"] end)
                |> Map.new(fn {bucket_action, action_rows} ->
                  {bucket_action, length(action_rows)}
                end)

              %{
                "time" => date <> "T00:00:00Z",
                "actions" => actions,
                "total" => Enum.reduce(actions, 0, fn {_k, count}, acc -> acc + count end)
              }
            end)
          end)

        {:ok,
         %{
           "bank_id" => ctx.bank,
           "period" => period,
           "trunc" => "day",
           "start" => DateTime.to_iso8601(start),
           "buckets" => buckets
         }}
    end
  end

  @impl true
  def update_document(ctx, _bank_id, document_id, attrs, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Enum.find(
             Map.values(state.documents),
             &(&1["bank_id"] == ctx.bank and &1["id"] == document_id)
           ) do
        nil ->
          {{:error, Error.new(:not_found, %{message: "document not found"})}, state}

        document ->
          updated =
            document
            |> Map.put("tags", List.wrap(attrs["tags"]))
            |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

          documents = Map.put(state.documents, {ctx.bank, document_id}, updated)

          memory_units =
            Enum.map(state.memory_units, fn unit ->
              if unit["bank_id"] == ctx.bank and unit["document_ref"] == document_id do
                Map.put(unit, "tags", List.wrap(attrs["tags"]))
              else
                unit
              end
            end)

          {{:ok, %{"success" => true}},
           %{state | documents: documents, memory_units: memory_units}}
      end
    end)
  end

  @impl true
  def delete_document(ctx, _bank_id, document_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.documents, {ctx.bank, document_id}) do
        nil ->
          {{:error, Error.new(:not_found, %{message: "document not found"})}, state}

        _document ->
          {deleted_units, kept_units} =
            Enum.split_with(
              state.memory_units,
              &(&1["bank_id"] == ctx.bank and &1["document_ref"] == document_id)
            )

          documents = Map.delete(state.documents, {ctx.bank, document_id})

          response = %{
            "success" => true,
            "message" =>
              "Document '#{document_id}' and #{length(deleted_units)} associated memory units deleted successfully",
            "document_id" => document_id,
            "memory_units_deleted" => length(deleted_units)
          }

          {{:ok, response}, %{state | documents: documents, memory_units: kept_units}}
      end
    end)
  end

  @impl true
  def reprocess_document(ctx, _bank_id, document_id, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1.documents, {ctx.bank, document_id})) do
      nil ->
        {:error, Error.new(:not_found, %{message: "document not found"})}

      _document ->
        {:ok, %{"success" => true, "operation_id" => "reprocess-op-1", "items_count" => 1}}
    end
  end

  @impl true
  def memory_graph(ctx, params, _opts) do
    limit = Map.get(params, "limit", 100)

    units =
      Agent.get(__MODULE__, fn state ->
        state.memory_units
        |> Enum.filter(&(&1["bank_id"] == ctx.bank))
        |> Enum.filter(fn unit ->
          is_nil(params["type"]) or unit["type"] == params["type"]
        end)
        |> Enum.filter(fn unit ->
          is_nil(params["document_id"]) or unit["document_ref"] == params["document_id"]
        end)
        |> Enum.filter(fn unit ->
          is_nil(params["chunk_id"]) or unit["id"] == params["chunk_id"]
        end)
        |> Enum.take(limit)
      end)

    {:ok,
     %{
       "nodes" =>
         Enum.map(units, fn unit ->
           %{
             "data" => %{
               "id" => unit["id"],
               "label" => unit["content"],
               "text" => unit["content"],
               "date" => unit["mentioned_at"],
               "context" => unit["context"] || "",
               "entities" => Enum.join(unit["entities"] || [], ", "),
               "color" => "#42a5f5"
             }
           }
         end),
       "edges" => [],
       "table_rows" =>
         Enum.map(units, fn unit ->
           %{
             "id" => unit["id"],
             "text" => unit["content"],
             "context" => unit["context"] || "",
             "occurred_start" => unit["occurred_start"],
             "occurred_end" => unit["occurred_end"],
             "mentioned_at" => unit["mentioned_at"],
             "date" => unit["mentioned_at"],
             "entities" => Enum.join(unit["entities"] || [], ", "),
             "document_id" => unit["document_ref"],
             "chunk_id" => unit["id"],
             "fact_type" => unit["type"],
             "tags" => unit["tags"] || [],
             "created_at" => unit["created_at"],
             "proof_count" => unit["proof_count"] || 1
           }
         end),
       "total_units" => length(units),
       "limit" => limit
     }}
  end

  @impl true
  def get_chunk(ctx, chunk_id, _opts) do
    case Agent.get(__MODULE__, fn state ->
           Enum.find(state.memory_units, &(&1["bank_id"] == ctx.bank and &1["id"] == chunk_id))
         end) do
      nil ->
        {:error, Error.new(:not_found, %{message: "chunk not found"})}

      unit ->
        {:ok,
         %{
           "chunk_id" => unit["id"],
           "document_id" => unit["document_ref"],
           "bank_id" => ctx.bank,
           "chunk_index" => 0,
           "chunk_text" => unit["content"],
           "created_at" => unit["created_at"] || unit["mentioned_at"]
         }}
    end
  end

  @impl true
  def list_operations(ctx, params, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.list_operations(ctx, params, opts)
  end

  @impl true
  def get_operation(ctx, operation_id, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.get_operation(ctx, operation_id, opts)
  end

  @impl true
  def cancel_operation(ctx, operation_id, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.cancel_operation(ctx, operation_id, opts)
  end

  @impl true
  def retry_operation(ctx, operation_id, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.retry_operation(ctx, operation_id, opts)
  end

  @impl true
  def recover_consolidation(_ctx, bank_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.banks, bank_id) do
        :error ->
          {{:error, Error.new(:not_found, %{message: "bank not found"})}, state}

        {:ok, _bank} ->
          {retried_units, kept_units} =
            Enum.split_with(state.memory_units, fn unit ->
              unit["bank_id"] == bank_id and unit["type"] in ["experience", "world"] and
                not is_nil(unit["consolidation_failed_at"])
            end)

          normalized_retried =
            Enum.map(retried_units, fn unit ->
              unit
              |> Map.put("consolidated_at", nil)
              |> Map.put("consolidation_failed_at", nil)
            end)

          response = %{"retried_count" => length(retried_units)}

          {{:ok, response}, %{state | memory_units: normalized_retried ++ kept_units}}
      end
    end)
  end

  defp fake_memories_timeseries_config("1h"),
    do: %{period: "1h", trunc: "minute", count: 60, step_seconds: 60}

  defp fake_memories_timeseries_config("12h"),
    do: %{period: "12h", trunc: "hour", count: 12, step_seconds: 3600}

  defp fake_memories_timeseries_config("1d"),
    do: %{period: "1d", trunc: "hour", count: 24, step_seconds: 3600}

  defp fake_memories_timeseries_config("30d"),
    do: %{period: "30d", trunc: "day", count: 30, step_seconds: 86_400}

  defp fake_memories_timeseries_config("90d"),
    do: %{period: "90d", trunc: "day", count: 90, step_seconds: 86_400}

  defp fake_memories_timeseries_config(_period),
    do: %{period: "7d", trunc: "day", count: 7, step_seconds: 86_400}

  defp fake_normalize_memories_timeseries_time_field(time_field)
       when time_field in ["created_at", "mentioned_at", "occurred_start"],
       do: time_field

  defp fake_normalize_memories_timeseries_time_field(_time_field), do: "created_at"

  defp fake_memories_timeseries_anchor("minute") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{now | second: 0, microsecond: {0, 0}}
  end

  defp fake_memories_timeseries_anchor("hour") do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{now | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp fake_memories_timeseries_anchor(_trunc) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp fake_memories_timeseries_unit_time(unit, "mentioned_at") do
    parse_datetime(unit["mentioned_at"]) || fake_memories_timeseries_unit_time(unit, "created_at")
  end

  defp fake_memories_timeseries_unit_time(unit, "occurred_start") do
    parse_datetime(unit["occurred_start"]) ||
      fake_memories_timeseries_unit_time(unit, "created_at")
  end

  defp fake_memories_timeseries_unit_time(unit, _time_field) do
    parse_datetime(unit["created_at"]) || parse_datetime(unit["inserted_at"]) ||
      parse_datetime(unit["mentioned_at"]) || DateTime.utc_now()
  end

  defp fake_memories_timeseries_truncate(datetime, "minute"),
    do: %{DateTime.truncate(datetime, :second) | second: 0, microsecond: {0, 0}}

  defp fake_memories_timeseries_truncate(datetime, "hour"),
    do: %{DateTime.truncate(datetime, :second) | minute: 0, second: 0, microsecond: {0, 0}}

  defp fake_memories_timeseries_truncate(datetime, _trunc),
    do: %{
      DateTime.truncate(datetime, :second)
      | hour: 0,
        minute: 0,
        second: 0,
        microsecond: {0, 0}
    }

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp fake_audit_log_duration_ms(%{"started_at" => started_at, "ended_at" => ended_at}) do
    with %DateTime{} = started_at <- normalize_datetime(started_at),
         %DateTime{} = ended_at <- normalize_datetime(ended_at) do
      DateTime.diff(ended_at, started_at, :millisecond)
    else
      _ -> nil
    end
  end

  defp fake_audit_period_start("1d"),
    do: DateTime.add(DateTime.utc_now(), -1 * 24 * 60 * 60, :second)

  defp fake_audit_period_start("30d"),
    do: DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)

  defp fake_audit_period_start(_period),
    do: DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)

  @impl true
  def clear_observations(ctx, _bank_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      {deleted, kept} =
        Enum.split_with(
          state.memory_units,
          &(&1["bank_id"] == ctx.bank and &1["type"] == "observation")
        )

      {{:ok, %{"deleted_count" => length(deleted)}}, %{state | memory_units: kept}}
    end)
  end

  @impl true
  def clear_memory_observations(ctx, _bank_id, memory_id, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      {deleted, kept} =
        Enum.split_with(state.memory_units, fn unit ->
          unit["bank_id"] == ctx.bank and unit["type"] == "observation" and
            memory_id in List.wrap(unit["source_fact_ids"] || unit["source_memory_ids"])
        end)

      {{:ok, %{"deleted_count" => length(deleted)}}, %{state | memory_units: kept}}
    end)
  end

  def backfill_embeddings(ctx, payload, _opts) do
    target_profile = Map.get(payload, "target_profile", %{})
    bank_id = Map.get(payload, "bank_id", ctx.bank)

    Agent.update(__MODULE__, fn state ->
      memory_units =
        Enum.map(state.memory_units, fn unit ->
          if unit["bank_id"] == bank_id do
            unit
            |> Map.put("embedded_by", target_profile["model_id"])
            |> Map.put("embedded_dim", target_profile["embedding_dim"])
          else
            unit
          end
        end)

      %{state | memory_units: memory_units}
    end)

    {:ok,
     %{
       "bank_id" => bank_id,
       "updated_count" => count_bank_units(bank_id),
       "target_profile" => target_profile
     }}
  end

  defp default_bank(bank_id) do
    %{
      "id" => bank_id,
      "bank_id" => bank_id,
      "name" => bank_id,
      "mission" => "",
      "disposition" => %{},
      "auto_consolidate" => false,
      "config_overrides" => %{}
    }
  end

  defp embedding_profile(bank) do
    overrides = Map.get(bank, "config_overrides", %{})

    %{
      "model_id" => Map.get(overrides, "embed_model", "BAAI/bge-small-en-v1.5"),
      "embedding_dim" => Map.get(overrides, "embedding_dim", 384)
    }
  end

  defp count_bank_units(bank_id) do
    Agent.get(__MODULE__, fn state ->
      Enum.count(state.memory_units, &(&1["bank_id"] == bank_id))
    end)
  end

  defp export_bank_config(bank) do
    bank
    |> Map.get("config_overrides", %{})
    |> Map.take(Foresight.BankTemplate.Schema.template_config_field_names())
  end

  defp export_directives(bank_id) do
    Agent.get(__MODULE__, fn state ->
      state.directives
      |> Enum.filter(fn {{directive_bank_id, _id}, _directive} ->
        directive_bank_id == bank_id
      end)
      |> Enum.map(fn {_key, directive} ->
        %{
          "name" => directive["name"],
          "content" => directive["content"],
          "priority" => directive["priority"],
          "is_active" => directive["is_active"],
          "tags" => directive["tags"] || []
        }
      end)
      |> Enum.sort_by(& &1["name"])
    end)
  end

  defp maybe_filter_fake_active(items, true),
    do: Enum.filter(items, &Map.get(&1, "is_active", true))

  defp maybe_filter_fake_active(items, false), do: items

  defp maybe_filter_fake_tags(items, []), do: items

  defp maybe_filter_fake_tags(items, tags) do
    Enum.filter(items, fn item ->
      item_tags = Map.get(item, "tags", [])
      Enum.all?(tags, &(&1 in item_tags))
    end)
  end

  defp fake_mental_model_record(bank_id, attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    source_query = Map.fetch!(attrs, "source_query")

    %{
      "id" => Map.fetch!(attrs, "id"),
      "bank_id" => bank_id,
      "name" => Map.get(attrs, "name", Map.fetch!(attrs, "id")),
      "title" => Map.get(attrs, "name", Map.fetch!(attrs, "id")),
      "original_text" => "Pending mental model content generation for #{source_query}",
      "tags" => Map.get(attrs, "tags", []),
      "created_at" => Map.get(attrs, "created_at", now),
      "metadata" => %{
        "document_type" => "mental_model",
        "source_query" => source_query,
        "max_tokens" => Map.get(attrs, "max_tokens", 2048),
        "trigger" => Map.get(attrs, "trigger", %{}),
        "reflect_response" => Map.get(attrs, "reflect_response"),
        "last_refreshed_at" => Map.get(attrs, "last_refreshed_at"),
        "history" => Map.get(attrs, "history", [])
      }
    }
  end

  defp fake_mental_model_response(model, detail) do
    metadata = Map.get(model, "metadata", %{})

    base = %{
      "id" => model["id"],
      "bank_id" => model["bank_id"],
      "name" => model["name"] || model["title"] || model["id"],
      "source_query" => metadata["source_query"],
      "tags" => model["tags"] || [],
      "max_tokens" => metadata["max_tokens"] || 2048,
      "trigger" => metadata["trigger"] || %{},
      "created_at" => model["created_at"],
      "last_refreshed_at" => metadata["last_refreshed_at"]
    }

    case detail do
      "metadata" ->
        base

      "content" ->
        Map.put(base, "content", model["original_text"])

      _full ->
        base
        |> Map.put("content", model["original_text"])
        |> Map.put("reflect_response", metadata["reflect_response"])
        |> Map.put("is_stale", metadata["is_stale"])
    end
  end

  defp append_mental_model_history(metadata, previous_content) do
    entry = %{
      "previous_content" => previous_content,
      "changed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "previous_reflect_response" => slim_reflect_response(metadata["reflect_response"])
    }

    [entry | List.wrap(metadata["history"])]
  end

  defp slim_reflect_response(%{"based_on" => based_on}), do: %{"based_on" => based_on}
  defp slim_reflect_response(_other), do: nil

  defp export_mental_models(bank_id) do
    Agent.get(__MODULE__, fn state ->
      state.mental_models
      |> Enum.filter(fn {{model_bank_id, _id}, _model} -> model_bank_id == bank_id end)
      |> Enum.map(fn {_key, model} ->
        metadata = model["metadata"] || %{}

        %{
          "id" => model["id"],
          "name" => model["name"] || model["title"] || model["id"],
          "source_query" => metadata["source_query"] || model["title"] || model["id"],
          "tags" => model["tags"] || [],
          "max_tokens" => metadata["max_tokens"] || 2048,
          "trigger" => metadata["trigger"] || %{}
        }
      end)
      |> Enum.sort_by(& &1["id"])
    end)
  end

  defp normalize_bank_template_config(nil), do: %{}
  defp normalize_bank_template_config(config) when is_map(config), do: Map.new(config)
  defp normalize_bank_template_config(_other), do: %{}

  defp upsert_template_directives(existing, bank_id, directives) do
    Enum.reduce(directives, existing, fn directive, acc ->
      {existing_key, existing_directive} =
        Enum.find(acc, fn
          {{directive_bank_id, _id}, stored_directive} ->
            directive_bank_id == bank_id and stored_directive["name"] == directive["name"]
        end) || {nil, nil}

      key = existing_key || {bank_id, System.unique_integer([:positive]) |> Integer.to_string()}

      stored =
        (existing_directive || %{})
        |> Map.merge(%{
          "id" => elem(key, 1),
          "bank_id" => bank_id,
          "name" => directive["name"],
          "content" => directive["content"],
          "priority" => Map.get(directive, "priority", 0),
          "is_active" => Map.get(directive, "is_active", true),
          "tags" => Map.get(directive, "tags", [])
        })

      Map.put(acc, key, stored)
    end)
  end

  defp upsert_template_mental_models(existing, bank_id, mental_models) do
    Enum.reduce(mental_models, existing, fn model, acc ->
      key = {bank_id, model["id"]}
      current = Map.get(acc, key, %{})

      stored = %{
        "id" => model["id"],
        "bank_id" => bank_id,
        "name" => model["name"],
        "title" => model["name"],
        "original_text" =>
          current["original_text"] ||
            "Pending mental model content generation for #{model["source_query"]}",
        "tags" => Map.get(model, "tags", []),
        "metadata" => %{
          "document_type" => "mental_model",
          "source_query" => model["source_query"],
          "max_tokens" => Map.get(model, "max_tokens", 2048),
          "trigger" => Map.get(model, "trigger", %{})
        }
      }

      Map.put(acc, key, stored)
    end)
  end

  defp validate_template_manifest(%{"version" => version} = manifest) when is_binary(version) do
    with :ok <- validate_optional_manifest_map(manifest, "bank"),
         :ok <- validate_template_directives(List.wrap(manifest["directives"])),
         :ok <- validate_template_mental_models(List.wrap(manifest["mental_models"])) do
      :ok
    end
  end

  defp validate_template_manifest(_manifest) do
    {:error,
     Foresight.Error.new(:invalid_request, %{message: "template manifest requires version"})}
  end

  defp validate_optional_manifest_map(manifest, key) do
    case Map.get(manifest, key) do
      nil ->
        :ok

      value when is_map(value) ->
        :ok

      _other ->
        {:error, Foresight.Error.new(:invalid_request, %{message: "#{key} must be an object"})}
    end
  end

  defp validate_template_directives(directives) do
    if Enum.all?(directives, &(is_map(&1) and is_binary(&1["name"]) and is_binary(&1["content"]))) do
      :ok
    else
      {:error,
       Foresight.Error.new(:invalid_request, %{
         message: "directives must include name and content"
       })}
    end
  end

  defp validate_template_mental_models(models) do
    if Enum.all?(
         models,
         &(is_map(&1) and is_binary(&1["id"]) and is_binary(&1["name"]) and
             is_binary(&1["source_query"]))
       ) do
      :ok
    else
      {:error,
       Foresight.Error.new(:invalid_request, %{
         message: "mental_models must include id, name, and source_query"
       })}
    end
  end

  defp merge_documents(documents, bank_id, items) do
    Enum.reduce(items, documents, fn item, acc ->
      case document_ref(item) do
        nil ->
          acc

        doc_id ->
          key = {bank_id, doc_id}
          existing = Map.get(acc, key, %{"bank_id" => bank_id, "id" => doc_id})

          title = item["document_title"] || get_in(item, ["metadata", "document_title"])

          document =
            Map.merge(existing, %{
              "title" => title || existing["title"],
              "original_text" =>
                item["document_text"] || get_in(item, ["metadata", "document_text"]) ||
                  existing["original_text"],
              "content_hash" => nil,
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "text_length" => nil,
              "tags" =>
                item["document_tags"] || get_in(item, ["metadata", "document_tags"]) ||
                  item["tags"] || existing["tags"] || [],
              "metadata" =>
                item
                |> Map.get("metadata", Map.get(existing, "metadata", %{}))
                |> Map.drop(["document_id", "document_title", "document_tags"])
            })

          Map.put(acc, key, document)
      end
    end)
  end

  defp requested_scopes(payload) do
    cond do
      is_list(payload["scope_keys"]) ->
        payload["scope_keys"]

      is_list(payload["tag_scopes"]) ->
        payload["tag_scopes"]
        |> Enum.map(fn
          %{"scope_key" => scope_key} when is_binary(scope_key) ->
            scope_key

          %{"tags" => tags, "observation_scopes" => scopes} when is_list(tags) ->
            build_scope_key(tags, normalize_scope_map(scopes))

          %{"tags" => tags} when is_list(tags) ->
            build_scope_key(tags, %{})

          tags when is_list(tags) ->
            build_scope_key(tags, %{})

          _other ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      true ->
        []
    end
  end

  defp observation_for_scope(bank_id, scope, units) do
    tags = scope_tags(scope)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    source_fact_ids = source_fact_ids_for_units(units)

    %{
      "id" => System.unique_integer([:positive]) |> Integer.to_string(),
      "bank_id" => bank_id,
      "content" => observation_text(scope, units),
      "context" => "consolidation",
      "type" => "observation",
      "tags" => tags,
      "metadata" => %{
        "generated_by" => "consolidation",
        "scope_key" => scope,
        "source_fact_ids" => source_fact_ids
      },
      "document_ref" => mental_model_id(scope),
      "embedding" => List.duplicate(0.0, 384),
      "embedded_dim" => 384,
      "mentioned_at" => now,
      "proof_count" => length(units),
      "source_memory_ids" => Enum.map(units, & &1["id"]),
      "consolidated_at" => now,
      "observation_scopes" => scope_observation_scopes(scope)
    }
  end

  defp mental_model_for_scope(bank_id, scope, observation) do
    tags = scope_tags(scope)

    %{
      "id" => mental_model_id(scope),
      "bank_id" => bank_id,
      "title" => mental_model_title(tags),
      "original_text" => observation["content"],
      "content_hash" => nil,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "text_length" => nil,
      "tags" => tags,
      "metadata" => %{
        "document_type" => "mental_model",
        "scope_key" => scope,
        "observation_scopes" => scope_observation_scopes(scope),
        "observation_id" => observation["id"],
        "source_memory_ids" => observation["source_memory_ids"],
        "source_fact_ids" => observation["metadata"]["source_fact_ids"] || []
      }
    }
  end

  defp source_fact_ids_for_units(units) do
    units
    |> Enum.flat_map(fn unit ->
      case List.wrap(unit["source_memory_ids"]) do
        [] -> [unit["id"]]
        ids -> ids
      end
    end)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_tag_scope(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_observation_scopes(item) when is_map(item) do
    item
    |> Map.get("observation_scopes", get_in(item, ["metadata", "observation_scopes"]) || %{})
    |> normalize_scope_map()
  end

  defp normalize_scope_map(%{} = scopes) do
    scopes
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_scope_value(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize_scope_map(_other), do: %{}

  defp normalize_scope_value(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_scope_value(value) when is_binary(value), do: value
  defp normalize_scope_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_scope_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_scope_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_scope_value(value), do: inspect(value)

  defp scope_key_for_item(item) do
    build_scope_key(List.wrap(item["tags"]), normalize_observation_scopes(item))
  end

  defp scope_key_for_unit(unit) do
    build_scope_key(unit["tags"] || [], unit["observation_scopes"] || %{})
  end

  defp build_scope_key(tags, scopes) do
    tag_key =
      case normalize_tag_scope(tags) do
        [] -> "__untagged__"
        normalized -> Enum.join(normalized, "||")
      end

    scope_key =
      scopes
      |> Enum.map(fn {key, value} -> "#{key}=#{encode_scope_value(value)}" end)
      |> Enum.join("&&")

    if scope_key == "", do: tag_key, else: "#{tag_key}##{scope_key}"
  end

  defp encode_scope_value(value) when is_list(value), do: Enum.join(value, "|")
  defp encode_scope_value(value), do: to_string(value)

  defp scope_key([]), do: "__untagged__"
  defp scope_key(tags), do: build_scope_key(tags, %{})

  defp scope_tags("__untagged__"), do: []

  defp scope_tags(scope_key) when is_binary(scope_key) do
    scope_key
    |> String.split("##", parts: 2)
    |> List.first()
    |> case do
      "__untagged__" -> []
      key -> String.split(key, "||", trim: true)
    end
  end

  defp scope_observation_scopes(scope_key) do
    case String.split(scope_key, "##", parts: 2) do
      [_tags] ->
        %{}

      [_tags, encoded_scopes] ->
        encoded_scopes
        |> String.split("&&", trim: true)
        |> Enum.map(fn pair ->
          case String.split(pair, "=", parts: 2) do
            [key, value] ->
              parsed =
                if String.contains?(value, "|"),
                  do: String.split(value, "|", trim: true),
                  else: value

              {key, parsed}

            [key] ->
              {key, ""}
          end
        end)
        |> Map.new()
    end
  end

  defp observation_text(scope, units) do
    scope_label =
      case scope_tags(scope) do
        [] -> "untagged"
        tags -> Enum.join(tags, ", ")
      end

    summary =
      units
      |> Enum.map(&String.trim(&1["content"]))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(3)
      |> Enum.join(" | ")

    "Observation for #{scope_label}: #{summary}"
  end

  defp mental_model_id(scope) when is_binary(scope), do: "mental-model:" <> scope
  defp mental_model_id(scope), do: "mental-model:" <> scope_key(scope)

  defp maybe_put_bank_field(bank, _key, nil), do: bank
  defp maybe_put_bank_field(bank, key, value), do: Map.put(bank, key, value)

  defp mental_model_title([]), do: "Mental Model"
  defp mental_model_title(tags), do: "Mental Model: " <> Enum.join(tags, ", ")

  defp document_ref(item) do
    item["document_id"] || item["document_ref"] || get_in(item, ["metadata", "document_id"])
  end

  defp fake_entity_states(results) do
    results
    |> Enum.flat_map(&Map.get(&1, "entities", []))
    |> Enum.uniq()
    |> Map.new(fn name ->
      {name,
       %{
         "entity_id" => name,
         "canonical_name" => name,
         "observations" =>
           results
           |> Enum.filter(&(name in Map.get(&1, "entities", [])))
           |> Enum.map(fn result ->
             %{"text" => result["text"], "mentioned_at" => result["mentioned_at"]}
           end)
       }}
    end)
  end

  defp fake_chunks(results) do
    Map.new(results, fn result ->
      {result["id"],
       %{
         "id" => result["id"],
         "text" => result["text"],
         "chunk_index" => 0,
         "truncated" => false
       }}
    end)
  end

  defp attach_entities(state, bank_id, units) do
    Enum.reduce(units, state, fn unit, acc ->
      names = Foresight.EntityExtractors.Simple.extract(unit["content"])

      {acc, entity_ids} =
        Enum.reduce(names, {acc, []}, fn name, {entity_acc, ids} ->
          normalized_name = String.downcase(name)
          entity_key = "#{bank_id}:#{normalized_name}"
          entity = Map.get(entity_acc.entities, entity_key)

          saved =
            if entity do
              entity
              |> Map.update!("mention_count", &(&1 + 1))
              |> Map.put("last_seen", unit["mentioned_at"])
            else
              %{
                "id" => entity_key,
                "bank_id" => bank_id,
                "canonical_name" => name,
                "mention_count" => 1,
                "first_seen" => unit["mentioned_at"],
                "last_seen" => unit["mentioned_at"]
              }
            end

          next_acc = %{entity_acc | entities: Map.put(entity_acc.entities, entity_key, saved)}
          {next_acc, [entity_key | ids]}
        end)

      attach_entity_links(acc, bank_id, entity_ids |> Enum.reverse() |> Enum.uniq())
    end)
  end

  defp attach_entity_links(state, _bank_id, [_single]), do: state
  defp attach_entity_links(state, _bank_id, []), do: state

  defp attach_entity_links(state, bank_id, entity_ids) do
    Enum.reduce(canonical_pairs(entity_ids), state, fn {source_id, target_id}, acc ->
      key = "#{bank_id}:#{source_id}:#{target_id}:co_occurrence"

      link =
        Map.get(acc.entity_links, key, %{
          "id" => key,
          "bank_id" => bank_id,
          "source_entity_id" => source_id,
          "target_entity_id" => target_id,
          "link_type" => "co_occurrence",
          "weight" => 0
        })

      updated = Map.update!(link, "weight", &(&1 + 1))
      %{acc | entity_links: Map.put(acc.entity_links, key, updated)}
    end)
  end

  defp unit_type_allowed?(unit, types) when is_list(types), do: unit["type"] in types
  defp unit_type_allowed?(_unit, _types), do: true

  defp semantic_match?(unit, query) do
    haystack = "#{unit["content"]} #{unit["context"]}" |> String.downcase()
    tokens = query_tokens(query)
    required_hits = semantic_overlap_threshold(tokens)

    Enum.count(tokens, &String.contains?(haystack, &1)) >= required_hits
  end

  defp keyword_match?(unit, query) do
    haystack = "#{unit["content"]} #{unit["context"]}" |> String.downcase()

    query
    |> keyword_terms()
    |> Enum.any?(&String.contains?(haystack, &1))
  end

  defp source_expansion_mode?(%{"verification_mode" => "source_expansion"}), do: true
  defp source_expansion_mode?(_payload), do: false

  defp memory_breadth_mode?(%{"verification_mode" => "memory_breadth"}), do: true
  defp memory_breadth_mode?(_payload), do: false

  defp select_semantic_candidates(items, payload) do
    limit = semantic_candidate_limit(payload)

    if memory_breadth_mode?(payload) do
      {novel_family_items, _seen_families} =
        Enum.reduce(items, {[], MapSet.new()}, fn item, {acc, seen} ->
          case recall_memory_family_key(item) do
            family when is_binary(family) and family != "" ->
              if MapSet.member?(seen, family) do
                {acc, seen}
              else
                {[item | acc], MapSet.put(seen, family)}
              end

            _ ->
              {acc, seen}
          end
        end)

      novel_family_items = Enum.reverse(novel_family_items)
      novel_family_ids = MapSet.new(Enum.map(novel_family_items, & &1["id"]))

      repeated_family_items =
        items
        |> Enum.reject(&MapSet.member?(novel_family_ids, &1["id"]))

      novel_family_items
      |> Kernel.++(repeated_family_items)
      |> Enum.take(limit)
    else
      Enum.take(items, limit)
    end
  end

  defp reject_selected_semantic_candidates(items, selected_items) do
    selected_ids = MapSet.new(Enum.map(selected_items, & &1["id"]))
    Enum.reject(items, &MapSet.member?(selected_ids, &1["id"]))
  end

  defp source_expansion_shortfall_type(%{"source_shortfall_type" => type})
       when type in ["source_family", "source_lineage", "source_provenance", "raw_memory_breadth"] do
    type
  end

  defp source_expansion_shortfall_type(_payload), do: nil

  defp source_expansion_novel_only?(%{
         "verification_mode" => "source_expansion",
         "source_shortfall_type" => "source_provenance",
         "source_novel_only" => true
       }),
       do: true

  defp source_expansion_novel_only?(_payload), do: false

  defp graph_recall_units(units, query, payload) do
    query_entities =
      query
      |> EntityExtractor.extract()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    source_expansion? = source_expansion_mode?(payload)
    source_shortfall_type = source_expansion_shortfall_type(payload)

    if query_entities == [] and not source_expansion? do
      {[],
       %{
         "inactive" => [inactive_record(query, "graph_no_entity_seed")],
         "gated_out" => [
           inactive_record(query, "graph_no_entity_seed")
         ],
         "capped_out" => []
       }}
    else
      entity_seed_units =
        Enum.filter(units, fn unit ->
          unit_entities =
            unit["content"]
            |> EntityExtractor.extract()
            |> Enum.map(&String.downcase/1)

          Enum.any?(query_entities, &(&1 in unit_entities))
        end)

      source_seed_units =
        if source_expansion? do
          units
          |> Enum.filter(fn unit ->
            List.wrap(unit["source_fact_ids"] || unit["source_memory_ids"]) != [] and
              semantic_match?(unit, query)
          end)
          |> prioritize_source_expansion_seeds(query, payload, source_shortfall_type)
          |> Enum.take(source_expansion_seed_limit(payload, source_shortfall_type))
        else
          []
        end

      direct_units =
        (entity_seed_units ++ source_seed_units)
        |> Enum.uniq_by(& &1["id"])

      source_seed_ids = MapSet.new(Enum.map(source_seed_units, & &1["id"]))
      source_expansion_context = source_expansion_context(direct_units, source_seed_ids)
      seed_ids = MapSet.new(Enum.map(direct_units, & &1["id"]))

      {graph_units, frontier_filtered_out} =
        graph_traversal_units(
          units,
          direct_units,
          payload,
          source_seed_ids,
          query,
          source_expansion_context,
          source_shortfall_type
        )

      scored_units =
        graph_units
        |> Enum.map(fn %{
                         unit: unit,
                         hop: hop,
                         seed_overlap: seed_overlap,
                         frontier_overlap_count: frontier_overlap_count,
                         source_seed_overlap_count: source_overlap_count,
                         source_traversal_score: source_traversal_score,
                         source_shortfall_bonus: source_shortfall_bonus,
                         frontier_evidence: frontier_evidence
                       } ->
          source_seed? = MapSet.member?(source_seed_ids, unit["id"])

          item =
            unit
            |> Map.put("graph_hop", hop)
            |> Map.put("graph_seed_overlap_count", length(seed_overlap))
            |> Map.put("graph_frontier_overlap_count", frontier_overlap_count)
            |> Map.put("graph_source_seed", source_seed?)
            |> Map.put("graph_source_overlap_count", source_overlap_count)
            |> Map.put("graph_source_traversal_score", source_traversal_score)
            |> put_strategy_score(
              "graph",
              graph_score(
                unit,
                query_entities,
                seed_ids,
                query,
                hop,
                seed_overlap,
                source_seed?,
                source_overlap_count,
                source_shortfall_bonus
              )
            )
            |> Map.put("graph_source_shortfall_bonus", source_shortfall_bonus)
            |> Map.put("graph_source_frontier_group", frontier_evidence["group"])
            |> Map.put("graph_source_frontier_novel_count", frontier_evidence["novel_count"] || 0)
            |> Map.put("graph_source_frontier_priority", frontier_evidence["priority"])

          if source_expansion? do
            Map.put(item, "graph_source_expansion", true)
            |> Map.put("graph_source_shortfall_type", source_shortfall_type)
          else
            item
          end
        end)
        |> Enum.sort_by(fn unit -> {-Map.get(unit, "graph_score", 0.0), unit["id"]} end)

      items = Enum.take(scored_units, recall_budget(payload))

      diagnostics =
        %{
          "gated_out" => [],
          "capped_out" =>
            scored_units
            |> Enum.drop(recall_budget(payload))
            |> Enum.take(5)
            |> Enum.map(&gate_record(&1, "graph_score", "graph_candidate_cap"))
        }
        |> maybe_put_frontier_filtered_out(frontier_filtered_out)
        |> maybe_put_source_expansion_empty_diagnostics(query, source_expansion?, direct_units)

      {items, diagnostics}
    end
  end

  defp graph_traversal_units(
         _units,
         [],
         _payload,
         _source_seed_ids,
         _query,
         _source_expansion_context,
         _source_shortfall_type
       ),
       do: {[], []}

  defp graph_traversal_units(
         units,
         direct_units,
         payload,
         source_seed_ids,
         query,
         source_expansion_context,
         source_shortfall_type
       ) do
    budget = recall_budget(payload)
    source_expansion? = source_expansion_mode?(payload)
    source_novel_only? = source_expansion_novel_only?(payload)

    seeds =
      direct_units
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(fn unit ->
        frontier_evidence =
          if source_expansion? do
            source_expansion_frontier_evidence(
              unit,
              source_expansion_context,
              source_shortfall_type
            )
          else
            %{}
          end

        %{
          unit: unit,
          hop: 0,
          seed_overlap: [unit["id"]],
          frontier_overlap_count: 1,
          source_seed_overlap_count:
            if(MapSet.member?(source_seed_ids, unit["id"]), do: 1, else: 0),
          source_traversal_score: 0.0,
          source_shortfall_bonus: 0.0,
          frontier_evidence: frontier_evidence
        }
      end)

    seed_ids = MapSet.new(Enum.map(seeds, & &1.unit["id"]))

    {visited, _frontier, frontier_filtered_out} =
      Enum.reduce_while(1..@graph_max_hops, {seeds, seeds, []}, fn hop,
                                                                   {visited, frontier,
                                                                    filtered_out} ->
        frontier_ids = Enum.map(frontier, & &1.unit["id"])
        remaining_budget = max(budget - length(visited), 0)

        cond do
          frontier_ids == [] or remaining_budget == 0 ->
            {:halt, {visited, frontier, filtered_out}}

          true ->
            fetch_limit =
              if source_expansion? do
                min(remaining_budget * 3, max(remaining_budget, 1) * 3)
              else
                remaining_budget
              end

            candidate_frontier =
              units
              |> Enum.reject(fn unit ->
                Enum.any?(visited, &(&1.unit["id"] == unit["id"]))
              end)
              |> Enum.filter(fn unit ->
                Enum.any?(unit["source_memory_ids"] || [], &(&1 in frontier_ids))
              end)

            {filtered_frontier, filtered_records} =
              partition_source_expansion_novel_only(
                candidate_frontier,
                source_novel_only?,
                source_seed_ids,
                hop,
                source_expansion_context,
                source_shortfall_type
              )

            next_frontier =
              filtered_frontier
              |> Enum.take(fetch_limit)
              |> Enum.map(fn unit ->
                frontier_overlap =
                  unit["source_memory_ids"]
                  |> List.wrap()
                  |> Enum.filter(&(&1 in frontier_ids))

                seed_overlap =
                  unit["source_memory_ids"]
                  |> List.wrap()
                  |> Enum.filter(&MapSet.member?(seed_ids, &1))

                source_seed_overlap_count =
                  unit["source_memory_ids"]
                  |> List.wrap()
                  |> Enum.count(&MapSet.member?(source_seed_ids, &1))

                source_traversal_score =
                  if source_expansion? do
                    source_expansion_traversal_score(
                      unit,
                      query,
                      hop,
                      length(frontier_overlap),
                      source_seed_overlap_count,
                      source_expansion_context,
                      source_shortfall_type
                    )
                  else
                    0.0
                  end

                source_shortfall_bonus =
                  if source_expansion? do
                    source_expansion_shortfall_bonus(
                      unit,
                      source_expansion_context,
                      source_shortfall_type
                    )
                  else
                    0.0
                  end

                frontier_evidence =
                  if source_expansion? do
                    source_expansion_frontier_evidence(
                      unit,
                      source_expansion_context,
                      source_shortfall_type
                    )
                  else
                    %{}
                  end

                %{
                  unit: unit,
                  hop: hop,
                  seed_overlap: seed_overlap,
                  frontier_overlap_count: length(frontier_overlap),
                  source_seed_overlap_count: source_seed_overlap_count,
                  source_traversal_score: source_traversal_score,
                  source_shortfall_bonus: source_shortfall_bonus,
                  frontier_evidence: frontier_evidence
                }
              end)
              |> maybe_prioritize_source_expansion_frontier(
                source_expansion?,
                remaining_budget,
                source_expansion_context,
                source_shortfall_type
              )

            {:cont, {visited ++ next_frontier, next_frontier, filtered_out ++ filtered_records}}
        end
      end)

    {Enum.take(visited, budget), Enum.take(frontier_filtered_out, 5)}
  end

  defp maybe_put_frontier_filtered_out(diagnostics, []), do: diagnostics

  defp maybe_put_frontier_filtered_out(diagnostics, filtered_records) do
    Map.put(diagnostics, "frontier_filtered_out", filtered_records)
  end

  defp partition_source_expansion_novel_only(
         units,
         false,
         _source_seed_ids,
         _hop,
         _source_expansion_context,
         _source_shortfall_type
       ),
       do: {units, []}

  defp partition_source_expansion_novel_only(
         units,
         true,
         source_seed_ids,
         hop,
         source_expansion_context,
         source_shortfall_type
       ) do
    Enum.reduce(units, {[], []}, fn unit, {kept, filtered_out} ->
      if source_expansion_novel_candidate?(unit, source_seed_ids) do
        {[unit | kept], filtered_out}
      else
        record =
          source_expansion_frontier_filter_record(
            unit,
            hop,
            source_seed_ids,
            source_expansion_context,
            source_shortfall_type
          )

        {kept, [record | filtered_out]}
      end
    end)
    |> then(fn {kept, filtered_out} ->
      {Enum.reverse(kept), Enum.reverse(filtered_out)}
    end)
  end

  defp source_expansion_novel_candidate?(unit, source_seed_ids) do
    unit
    |> Map.get("source_memory_ids", [])
    |> MapSet.new()
    |> MapSet.difference(source_seed_ids)
    |> MapSet.size() > 0
  end

  defp source_expansion_frontier_filter_record(
         unit,
         hop,
         source_seed_ids,
         source_expansion_context,
         source_shortfall_type
       ) do
    frontier_evidence =
      source_expansion_frontier_evidence(
        unit,
        source_expansion_context,
        source_shortfall_type
      )

    %{
      "node_id" => unit["id"],
      "text" => unit["content"] || unit["text"],
      "score" => 0.0,
      "reasons" => ["source_novel_only_filter"],
      "reason" => "source_novel_only_filter",
      "evidence" => %{
        "hop" => hop,
        "source_seed_overlap_count" =>
          unit["source_memory_ids"]
          |> List.wrap()
          |> Enum.count(&MapSet.member?(source_seed_ids, &1)),
        "source_shortfall_type" => source_shortfall_type,
        "source_frontier_group" => frontier_evidence["group"],
        "source_frontier_novel_count" => frontier_evidence["novel_count"] || 0,
        "source_frontier_priority" => frontier_evidence["priority"],
        "source_expansion" => true
      }
    }
  end

  defp source_expansion_context(direct_units, source_seed_ids) do
    seed_document_families =
      direct_units
      |> Enum.filter(&MapSet.member?(source_seed_ids, &1["id"]))
      |> Enum.map(&source_expansion_document_family/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    seed_memory_families =
      direct_units
      |> Enum.filter(&MapSet.member?(source_seed_ids, &1["id"]))
      |> Enum.map(&source_expansion_memory_family/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{
      source_seed_ids: source_seed_ids,
      seed_document_families: seed_document_families,
      seed_memory_families: seed_memory_families
    }
  end

  defp source_expansion_shortfall_bonus(_unit, _context, nil), do: 0.0

  defp source_expansion_shortfall_bonus(unit, context, "source_family") do
    family_bonus =
      case source_expansion_document_family(unit) do
        nil ->
          0.0

        family ->
          if MapSet.member?(context.seed_document_families, family), do: 0.0, else: 0.9
      end

    Float.round(family_bonus, 6)
  end

  defp source_expansion_shortfall_bonus(unit, context, "raw_memory_breadth") do
    family_bonus =
      case source_expansion_memory_family(unit) do
        nil ->
          0.0

        family ->
          if MapSet.member?(context.seed_memory_families, family), do: 0.0, else: 1.1
      end

    source_bonus =
      unit
      |> Map.get("source_memory_ids", [])
      |> length()
      |> min(3)
      |> Kernel.*(0.1)

    Float.round(family_bonus + source_bonus, 6)
  end

  defp source_expansion_shortfall_bonus(unit, context, "source_lineage") do
    source_ids = unit |> Map.get("source_memory_ids", []) |> MapSet.new()

    shared_source_count =
      MapSet.intersection(source_ids, context.source_seed_ids) |> MapSet.size()

    novel_source_count = MapSet.difference(source_ids, context.source_seed_ids) |> MapSet.size()

    bonus =
      if shared_source_count > 0 and novel_source_count > 0 do
        min(novel_source_count, 3) * 0.85
      else
        0.0
      end

    Float.round(bonus, 6)
  end

  defp source_expansion_shortfall_bonus(unit, context, "source_provenance") do
    novel_source_count =
      unit
      |> Map.get("source_memory_ids", [])
      |> MapSet.new()
      |> MapSet.difference(context.source_seed_ids)
      |> MapSet.size()

    Float.round(min(novel_source_count, 3) * 0.75, 6)
  end

  defp source_expansion_document_family(%{"document_id" => document_id})
       when is_binary(document_id) and document_id != "" do
    "document_family:#{document_id}"
  end

  defp source_expansion_document_family(%{"document_ref" => document_ref})
       when is_binary(document_ref) and document_ref != "" do
    "document_family:#{document_ref}"
  end

  defp source_expansion_document_family(_unit), do: nil

  defp source_expansion_memory_family(%{"document_id" => document_id})
       when is_binary(document_id) and document_id != "" do
    "memory_family:document:#{document_id}"
  end

  defp source_expansion_memory_family(%{"document_ref" => document_ref})
       when is_binary(document_ref) and document_ref != "" do
    "memory_family:document:#{document_ref}"
  end

  defp source_expansion_memory_family(%{"id" => id}) when is_binary(id) and id != "" do
    "memory_family:memory:#{id}"
  end

  defp source_expansion_memory_family(_unit), do: nil

  defp source_expansion_frontier_evidence(_unit, _context, nil), do: %{}

  defp source_expansion_frontier_evidence(unit, context, "source_family") do
    group = source_expansion_document_family(unit)
    novel? = is_binary(group) and not MapSet.member?(context.seed_document_families, group)

    %{
      "group" => group,
      "novel_count" => if(novel?, do: 1, else: 0),
      "priority" => if(novel?, do: "novel_document_family", else: "existing_document_family")
    }
  end

  defp source_expansion_frontier_evidence(unit, context, "raw_memory_breadth") do
    group = source_expansion_memory_family(unit)
    novel? = is_binary(group) and not MapSet.member?(context.seed_memory_families, group)

    %{
      "group" => group,
      "novel_count" => if(novel?, do: 1, else: 0),
      "priority" => if(novel?, do: "novel_memory_family", else: "existing_memory_family")
    }
  end

  defp source_expansion_frontier_evidence(unit, context, "source_lineage") do
    source_ids = unit |> Map.get("source_memory_ids", []) |> Enum.map(&to_string/1)
    novel_source_ids = Enum.reject(source_ids, &MapSet.member?(context.source_seed_ids, &1))
    shared_source_count = Enum.count(source_ids, &MapSet.member?(context.source_seed_ids, &1))

    %{
      "group" => "source_lineage:#{Enum.sort(source_ids) |> Enum.join("|")}",
      "novel_count" => length(novel_source_ids),
      "priority" =>
        cond do
          shared_source_count > 0 and novel_source_ids != [] -> "extends_source_lineage"
          novel_source_ids != [] -> "novel_source_cluster"
          true -> "existing_source_cluster"
        end
    }
  end

  defp source_expansion_frontier_evidence(unit, context, "source_provenance") do
    source_ids = unit |> Map.get("source_memory_ids", []) |> Enum.map(&to_string/1)
    novel_source_ids = Enum.reject(source_ids, &MapSet.member?(context.source_seed_ids, &1))

    %{
      "group" => "source_cluster:#{Enum.sort(source_ids) |> Enum.join("|")}",
      "novel_count" => length(novel_source_ids),
      "priority" =>
        if(novel_source_ids != [], do: "novel_source_cluster", else: "existing_source_cluster")
    }
  end

  defp source_expansion_frontier_evidence(_unit, _context, _source_shortfall_type), do: %{}

  defp source_expansion_seed_limit(payload, nil), do: recall_budget(payload)
  defp source_expansion_seed_limit(%{"budget" => "low"}, _source_shortfall_type), do: 1
  defp source_expansion_seed_limit(%{"budget" => "mid"}, _source_shortfall_type), do: 2
  defp source_expansion_seed_limit(%{"budget" => "high"}, _source_shortfall_type), do: 2
  defp source_expansion_seed_limit(_payload, _source_shortfall_type), do: 2

  defp prioritize_source_expansion_seeds(units, _query, _payload, nil), do: units

  defp prioritize_source_expansion_seeds(units, query, _payload, source_shortfall_type) do
    units
    |> Enum.sort_by(fn unit ->
      {-source_expansion_seed_priority(unit, source_shortfall_type),
       -semantic_link_score(unit, query), unit["id"]}
    end)
  end

  defp source_expansion_seed_priority(unit, "source_family") do
    document_bonus =
      if is_binary(source_expansion_document_family(unit)), do: 2.0, else: 0.0

    source_breadth_bonus =
      unit
      |> Map.get("source_memory_ids", [])
      |> length()
      |> min(3)
      |> Kernel.*(0.15)

    Float.round(document_bonus + source_breadth_bonus, 6)
  end

  defp source_expansion_seed_priority(unit, "raw_memory_breadth") do
    family_bonus =
      if is_binary(source_expansion_memory_family(unit)),
        do: 2.2,
        else: 0.0

    source_breadth_bonus =
      unit
      |> Map.get("source_memory_ids", [])
      |> length()
      |> min(3)
      |> Kernel.*(0.25)

    Float.round(family_bonus + source_breadth_bonus, 6)
  end

  defp source_expansion_seed_priority(unit, "source_lineage") do
    source_ids = Map.get(unit, "source_memory_ids", [])
    multi_source_bonus = if length(source_ids) > 1, do: 2.0, else: 0.0
    source_breadth_bonus = min(length(source_ids), 3) * 0.35

    Float.round(multi_source_bonus + source_breadth_bonus, 6)
  end

  defp source_expansion_seed_priority(unit, "source_provenance") do
    unit
    |> Map.get("source_memory_ids", [])
    |> length()
    |> min(3)
    |> Kernel.*(0.85)
    |> Float.round(6)
  end

  defp source_expansion_seed_priority(_unit, _source_shortfall_type), do: 0.0

  defp temporal_recall_units(_units, nil, _query_timestamp, query, _payload) do
    {[],
     %{
       "inactive" => [inactive_record(query || "", "no_temporal_constraint")]
     }}
  end

  defp temporal_recall_units(units, constraint, query_timestamp, query, payload) do
    raw_entry_units =
      units
      |> Enum.filter(&within_temporal_constraint?(&1, constraint))
      |> Enum.sort_by(fn unit -> {compare_datetimes_desc(unit["mentioned_at"]), unit["id"]} end)
      |> Enum.take(temporal_entry_point_limit(payload))
      |> Enum.map(fn unit ->
        unit
        |> Map.put("temporal_semantic_score", temporal_query_score(unit, query))
      end)

    entry_units =
      raw_entry_units
      |> Enum.filter(&(Map.get(&1, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor))
      |> Enum.sort_by(fn unit ->
        {-Map.get(unit, "temporal_semantic_score", 0.0), unit["id"]}
      end)
      |> Enum.take(temporal_result_limit(payload))
      |> Enum.map(fn unit ->
        unit
        |> Map.put("temporal_hop", 0)
        |> Map.put(
          "temporal_seed_score",
          temporal_score(unit, constraint, query_timestamp)
        )
      end)

    entry_by_id = Map.new(entry_units, &{&1["id"], &1})
    seed_ids = Map.keys(entry_by_id) |> MapSet.new()
    budget = recall_budget(payload)

    frontier =
      Enum.map(entry_units, fn unit ->
        %{unit: unit, hop: 0}
      end)

    visited_ids = MapSet.new(Map.keys(entry_by_id))

    {visited, _frontier, _visited_ids} =
      Enum.reduce_while(1..@temporal_max_hops, {[], frontier, visited_ids}, fn hop,
                                                                               {visited, frontier,
                                                                                visited_ids} ->
        frontier_ids = Enum.map(frontier, & &1.unit["id"])
        remaining_budget = max(budget - length(entry_units) - length(visited), 0)

        cond do
          frontier_ids == [] or remaining_budget == 0 ->
            {:halt, {visited, frontier, visited_ids}}

          true ->
            next_frontier =
              units
              |> Enum.filter(fn unit ->
                unit["id"] not in frontier_ids and
                  not MapSet.member?(visited_ids, unit["id"]) and
                  Enum.any?(unit["source_memory_ids"] || [], &(&1 in frontier_ids))
              end)
              |> Enum.map(fn unit ->
                source_overlap =
                  unit["source_memory_ids"]
                  |> List.wrap()
                  |> Enum.filter(fn source_id ->
                    source_id in frontier_ids or MapSet.member?(seed_ids, source_id)
                  end)

                best_seed_score =
                  source_overlap
                  |> Enum.map(fn source_id ->
                    case Map.fetch(entry_by_id, source_id) do
                      {:ok, seed_unit} ->
                        Map.get(
                          seed_unit,
                          "temporal_seed_score",
                          Map.get(seed_unit, "score", 0.0)
                        )

                      :error ->
                        frontier
                        |> Enum.find_value(0.0, fn frontier_item ->
                          if frontier_item.unit["id"] == source_id,
                            do: Map.get(frontier_item.unit, "temporal_seed_score", 0.0),
                            else: nil
                        end)
                    end
                  end)
                  |> Enum.max(fn -> 0.0 end)

                unit
                |> Map.put("temporal_semantic_score", temporal_query_score(unit, query))
                |> Map.put("temporal_hop", hop)
                |> Map.put("temporal_source_overlap", source_overlap)
                |> Map.put("temporal_overlap_bonus", min(length(source_overlap), 3) * 0.05)
                |> Map.put(
                  "temporal_seed_score",
                  Float.round(best_seed_score * @temporal_decay, 6)
                )
                |> then(fn unit -> %{unit: unit, hop: hop} end)
              end)
              |> Enum.filter(fn %{unit: unit} ->
                Map.get(unit, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor
              end)
              |> Enum.sort_by(fn %{unit: unit} ->
                {-Map.get(unit, "temporal_seed_score", 0.0),
                 -Map.get(unit, "temporal_semantic_score", 0.0), unit["id"]}
              end)
              |> Enum.take(
                min(remaining_budget, temporal_result_limit(payload) * @temporal_per_source_limit)
              )

            next_visited_ids =
              Enum.reduce(next_frontier, visited_ids, fn %{unit: unit}, acc ->
                MapSet.put(acc, unit["id"])
              end)

            next_visited =
              next_frontier
              |> Enum.map(fn %{unit: unit} -> unit end)

            {:cont, {visited ++ next_visited, next_frontier, next_visited_ids}}
        end
      end)

    items =
      (entry_units ++ visited)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(fn unit ->
        put_strategy_score(
          unit,
          "temporal",
          temporal_runtime_score(unit, constraint, query_timestamp)
        )
      end)
      |> Enum.sort_by(fn unit -> {-Map.get(unit, "temporal_score", 0.0), unit["id"]} end)
      |> Enum.take(recall_budget(payload))

    diagnostics = %{
      "gated_out" =>
        raw_entry_units
        |> Enum.reject(
          &(Map.get(&1, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor)
        )
        |> Enum.take(5)
        |> Enum.map(&gate_record(&1, "temporal_semantic_score", "temporal_similarity_floor")),
      "capped_out" =>
        raw_entry_units
        |> Enum.filter(
          &(Map.get(&1, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor)
        )
        |> Enum.sort_by(fn unit ->
          {-Map.get(unit, "temporal_semantic_score", 0.0), unit["id"]}
        end)
        |> Enum.drop(temporal_result_limit(payload))
        |> Enum.take(5)
        |> Enum.map(&gate_record(&1, "temporal_semantic_score", "temporal_entry_cap"))
    }

    {items, diagnostics}
  end

  defp strategy_trace(
         _name,
         active,
         units,
         filtered_units,
         filter_reason_counts,
         filtered_out_records,
         diagnostics
       ) do
    %{
      "active" => active,
      "count" => length(filtered_units),
      "pre_filter_count" => length(units),
      "filtered_out_count" => max(length(units) - length(filtered_units), 0),
      "filtered_out_reason_counts" => filter_reason_counts,
      "contributed" => Enum.map(filtered_units, & &1["id"])
    }
    |> maybe_put_diagnostics(Map.put(diagnostics, "filtered_out", filtered_out_records))
  end

  defp gate_record(item, score_key, reason) do
    %{
      "node_id" => item["id"],
      "text" => item["text"] || item["content"],
      "score" => Map.get(item, score_key, 0.0),
      "score_key" => score_key,
      "reasons" => [reason],
      "reason" => reason,
      "evidence" => gate_record_evidence(item, score_key)
    }
  end

  defp gate_record_evidence(item, "semantic_score") do
    %{
      "semantic_score" => Map.get(item, "semantic_score", 0.0)
    }
  end

  defp gate_record_evidence(item, "keyword_score") do
    %{
      "keyword_score" => Map.get(item, "keyword_score", 0.0)
    }
  end

  defp gate_record_evidence(item, "graph_score") do
    %{
      "graph_score" => Map.get(item, "graph_score", 0.0),
      "hop" => Map.get(item, "graph_hop", 0),
      "seed_overlap_count" => Map.get(item, "graph_seed_overlap_count", 0),
      "frontier_overlap_count" => Map.get(item, "graph_frontier_overlap_count", 0),
      "source_seed" => Map.get(item, "graph_source_seed", false),
      "source_overlap_count" => Map.get(item, "graph_source_overlap_count", 0),
      "source_traversal_score" => Map.get(item, "graph_source_traversal_score", 0.0),
      "source_frontier_bonus" => Map.get(item, "graph_source_frontier_bonus", 0.0),
      "source_frontier_group" => Map.get(item, "graph_source_frontier_group"),
      "source_frontier_novel_count" => Map.get(item, "graph_source_frontier_novel_count", 0),
      "source_frontier_priority" => Map.get(item, "graph_source_frontier_priority"),
      "source_expansion" => Map.get(item, "graph_source_expansion", false)
    }
  end

  defp gate_record_evidence(item, "temporal_semantic_score") do
    %{
      "temporal_semantic_score" => Map.get(item, "temporal_semantic_score", 0.0),
      "hop" => Map.get(item, "temporal_hop", 0),
      "source_overlap_count" => item |> Map.get("temporal_source_overlap", []) |> length(),
      "seed_score" => Map.get(item, "temporal_seed_score", 0.0)
    }
  end

  defp gate_record_evidence(_item, _score_key), do: %{}

  defp inactive_record(text, reason) do
    %{
      "node_id" => nil,
      "text" => text,
      "score" => 0.0,
      "reasons" => [reason],
      "reason" => reason
    }
  end

  defp maybe_put_empty_diagnostics(
         %{
           "active" => true,
           "count" => 0,
           "pre_filter_count" => 0
         } = trace,
         query
       ) do
    diagnostics = Map.get(trace, "diagnostics", %{})

    has_other_failure_records? =
      Enum.any?(["inactive", "filtered_out", "gated_out", "capped_out", "empty"], fn key ->
        Map.get(diagnostics, key, []) != []
      end)

    if has_other_failure_records? do
      trace
    else
      Map.put(
        trace,
        "diagnostics",
        Map.put(diagnostics, "empty", [inactive_record(query, "no_matches_after_strategy")])
      )
    end
  end

  defp maybe_put_empty_diagnostics(trace, _query), do: trace

  defp maybe_put_fully_gated_diagnostics(
         %{
           "active" => true,
           "count" => 0,
           "pre_filter_count" => 0
         } = trace,
         query
       ) do
    diagnostics = Map.get(trace, "diagnostics", %{})
    gated_out = Map.get(diagnostics, "gated_out", [])

    has_other_primary_failure_records? =
      Enum.any?(["inactive", "filtered_out", "capped_out", "empty"], fn key ->
        Map.get(diagnostics, key, []) != []
      end)

    if gated_out != [] and not has_other_primary_failure_records? do
      gate_reason_counts =
        gated_out
        |> Enum.flat_map(&Map.get(&1, "reasons", [Map.get(&1, "reason")]))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      record =
        inactive_record(query, "all_candidates_gated_out")
        |> Map.put("reasons", gate_reason_counts |> Map.keys() |> Enum.sort())
        |> Map.put("gate_reason_counts", gate_reason_counts)

      Map.put(trace, "diagnostics", Map.put(diagnostics, "fully_gated", [record]))
    else
      trace
    end
  end

  defp maybe_put_fully_gated_diagnostics(trace, _query), do: trace

  defp maybe_put_diagnostics(trace, diagnostics) when diagnostics == %{}, do: trace
  defp maybe_put_diagnostics(trace, diagnostics), do: Map.put(trace, "diagnostics", diagnostics)

  defp maybe_put_strategy_mode(trace, %{source_expansion: true}) do
    Map.put(trace, "mode", "source_expansion")
  end

  defp maybe_put_strategy_mode(trace, _result), do: trace

  defp maybe_put_source_expansion_empty_diagnostics(
         diagnostics,
         query,
         true,
         direct_units
       )
       when direct_units == [] do
    Map.put(diagnostics, "empty", [inactive_record(query, "source_expansion_no_seed_match")])
  end

  defp maybe_put_source_expansion_empty_diagnostics(
         diagnostics,
         _query,
         _source_expansion?,
         _direct_units
       ),
       do: diagnostics

  defp filter_reason_counts(units, payload, question_date) do
    Enum.reduce(units, %{}, fn unit, reason_counts ->
      tag_match? = match_recall_tags?(unit["tags"], payload)
      timestamp_match? = match_query_timestamp?(unit, question_date)
      source_linked_match? = match_source_linked_only?(unit, payload)

      reasons =
        []
        |> maybe_add_filter_reason(not tag_match?, "tag_filter")
        |> maybe_add_filter_reason(not timestamp_match?, "query_timestamp_filter")
        |> maybe_add_filter_reason(not source_linked_match?, "source_linked_filter")

      Enum.reduce(reasons, reason_counts, fn reason, acc ->
        Map.update(acc, reason, 1, &(&1 + 1))
      end)
    end)
  end

  defp filter_out_records(units, payload, question_date) do
    units
    |> Enum.reduce([], fn unit, records ->
      tag_match? = match_recall_tags?(unit["tags"], payload)
      timestamp_match? = match_query_timestamp?(unit, question_date)
      source_linked_match? = match_source_linked_only?(unit, payload)

      case {tag_match?, timestamp_match?, source_linked_match?} do
        {true, true, true} ->
          records

        _ ->
          reasons =
            []
            |> maybe_add_filter_reason(not tag_match?, "tag_filter")
            |> maybe_add_filter_reason(not timestamp_match?, "query_timestamp_filter")
            |> maybe_add_filter_reason(not source_linked_match?, "source_linked_filter")

          [
            %{
              "node_id" => unit["id"],
              "text" => unit["text"] || unit["content"],
              "score" => unit["score"] || 0.0,
              "reasons" => Enum.sort(reasons)
            }
            | records
          ]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(5)
  end

  defp maybe_add_filter_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_filter_reason(reasons, false, _reason), do: reasons

  defp put_strategy_score(unit, strategy, score) do
    strategy_key = "#{strategy}_score"

    unit
    |> Map.put("score", score)
    |> Map.put(strategy_key, score)
  end

  defp unit_tags_match?(unit, tags, mode) when mode in ["all", "all_strict"] do
    Enum.all?(tags, &(&1 in unit["tags"]))
  end

  defp unit_tags_match?(unit, tags, _mode) do
    Enum.any?(tags, &(&1 in unit["tags"]))
  end

  defp match_recall_tags?(_tags, %{"tags" => nil, "tag_groups" => nil}), do: true
  defp match_recall_tags?(_tags, %{"tags" => [], "tag_groups" => nil}), do: true

  defp match_recall_tags?(tags, %{"tag_groups" => groups})
       when is_list(groups) and groups != [] do
    match_tag_groups?(tags, groups)
  end

  defp match_recall_tags?(tags, %{"tags" => requested, "tags_match" => mode})
       when is_list(requested) and requested != [] do
    match_tag_list?(tags, requested, mode || "any")
  end

  defp match_recall_tags?(_tags, _params), do: true

  defp match_tag_groups?(tags, groups) when is_list(groups) do
    Enum.all?(groups, &match_tag_group?(tags, &1))
  end

  defp match_tag_group?(tags, %{"tags" => requested} = group) when is_list(requested) do
    match_tag_list?(tags, requested, Map.get(group, "match", "any"))
  end

  defp match_tag_group?(tags, %{"and" => groups}) when is_list(groups) do
    Enum.all?(groups, &match_tag_group?(tags, &1))
  end

  defp match_tag_group?(tags, %{"or" => groups}) when is_list(groups) do
    Enum.any?(groups, &match_tag_group?(tags, &1))
  end

  defp match_tag_group?(tags, %{"not" => group}) when is_map(group) do
    not match_tag_group?(tags, group)
  end

  defp match_tag_group?(_tags, _group), do: false

  defp match_tag_list?(tags, requested, mode) do
    tags = List.wrap(tags || [])
    requested = Enum.uniq(requested)
    untagged? = tags == []

    case mode do
      "any" -> untagged? or Enum.any?(requested, &(&1 in tags))
      "all" -> untagged? or Enum.all?(requested, &(&1 in tags))
      "any_strict" -> not untagged? and Enum.any?(requested, &(&1 in tags))
      "all_strict" -> not untagged? and Enum.all?(requested, &(&1 in tags))
      _ -> untagged? or Enum.any?(requested, &(&1 in tags))
    end
  end

  defp match_query_timestamp?(_unit, nil), do: true

  defp match_query_timestamp?(unit, %DateTime{} = question_date) do
    case parse_query_timestamp(unit["mentioned_at"]) do
      %DateTime{} = mentioned_at -> DateTime.compare(mentioned_at, question_date) != :gt
      _ -> true
    end
  end

  defp match_source_linked_only?(unit, %{"source_linked_only" => true} = payload) do
    source_expansion_mode?(payload) and
      List.wrap(unit["source_fact_ids"] || unit["source_memory_ids"]) != []
  end

  defp match_source_linked_only?(_unit, _payload), do: true

  defp within_temporal_constraint?(unit, %{from: %DateTime{} = from_dt, to: %DateTime{} = to_dt}) do
    timestamp = unit_datetime(unit)

    case timestamp do
      %DateTime{} = datetime ->
        DateTime.compare(datetime, from_dt) != :lt and DateTime.compare(datetime, to_dt) != :gt

      _ ->
        false
    end
  end

  defp within_temporal_constraint?(_unit, _constraint), do: true

  defp validate_tag_filters(%{"tags" => tags, "tag_groups" => groups})
       when not is_nil(tags) and not is_nil(groups) do
    {:error,
     Error.new(:invalid_request, %{
       message:
         "'tags' and 'tag_groups' are mutually exclusive. Use 'tag_groups' for compound filtering."
     })}
  end

  defp validate_tag_filters(%{"tag_groups" => groups}) when is_list(groups), do: :ok
  defp validate_tag_filters(%{"tag_groups" => nil}), do: :ok

  defp validate_tag_filters(%{"tag_groups" => _invalid}) do
    {:error, Error.new(:invalid_request, %{message: "tag_groups must be a list when provided"})}
  end

  defp validate_tag_filters(_payload), do: :ok

  defp validate_query_timestamp(nil), do: :ok

  defp validate_query_timestamp(value) do
    case parse_query_timestamp(value) do
      %DateTime{} ->
        :ok

      _ ->
        {:error,
         Error.new(:invalid_request, %{
           message:
             "Invalid query_timestamp format. Expected ISO format (e.g., '2023-05-30T23:40:00')"
         })}
    end
  end

  defp parse_query_timestamp(nil), do: nil

  defp parse_query_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp extract_retain_items(items) do
    items
    |> Enum.flat_map(&extract_retain_item/1)
  end

  defp extract_retain_item(%{"content" => content} = item) when is_binary(content) do
    normalized = String.trim(content)

    if normalized != "" and Regex.match?(~r/[[:alnum:]]/u, normalized) do
      [Map.put(item, "content", normalized)]
    else
      []
    end
  end

  defp extract_retain_item(_item), do: []

  # Mirrors Storage.Ecto's caps on the free-form JSON a retain item may carry.
  @max_retain_metadata_bytes 65_536
  @max_retain_source_location_bytes 16_384

  defp validate_retain_item_sizes(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      with :ok <- validate_json_size(item, "metadata", @max_retain_metadata_bytes),
           :ok <-
             validate_json_size(item, "source_location", @max_retain_source_location_bytes) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_json_size(item, key, max_bytes) when is_map(item) do
    with %{} = value <- Map.get(item, key),
         {:ok, json} <- Jason.encode(value),
         true <- byte_size(json) > max_bytes do
      {:error,
       Error.new(:invalid_request, %{message: "#{key} exceeds #{max_bytes} bytes when encoded"})}
    else
      _ -> :ok
    end
  end

  defp validate_json_size(_item, _key, _max_bytes), do: :ok

  defp ensure_nonempty_retain_extraction([]) do
    {:error,
     Error.new(:invalid_request, %{
       message: "retain extracted zero facts from payload"
     })}
  end

  defp ensure_nonempty_retain_extraction(_items), do: :ok

  defp temporal_constraint(query, query_timestamp) when is_binary(query) do
    anchor = parse_query_timestamp(query_timestamp) || DateTime.utc_now()
    normalized_query = String.downcase(query)

    cond do
      String.contains?(normalized_query, "yesterday") ->
        day_constraint(Date.add(DateTime.to_date(anchor), -1))

      String.contains?(normalized_query, "today") ->
        day_constraint(DateTime.to_date(anchor))

      String.contains?(normalized_query, "tomorrow") ->
        day_constraint(Date.add(DateTime.to_date(anchor), 1))

      String.contains?(normalized_query, "last week") ->
        week_constraint(anchor, -1)

      String.contains?(normalized_query, "this week") ->
        week_constraint(anchor, 0)

      String.contains?(normalized_query, "last month") ->
        month_constraint(anchor, -1)

      String.contains?(normalized_query, "this month") ->
        month_constraint(anchor, 0)

      date = extract_explicit_date(normalized_query) ->
        day_constraint(date)

      true ->
        nil
    end
  end

  defp temporal_constraint(_query, _query_timestamp), do: nil

  defp extract_explicit_date(query) do
    case Regex.run(~r/\b(\d{4}-\d{2}-\d{2})\b/, query, capture: :all_but_first) do
      [value] ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp day_constraint(%Date{} = date) do
    %{from: start_of_day(date), to: end_of_day(date)}
  end

  defp week_constraint(anchor, offset_weeks) do
    current_date = DateTime.to_date(anchor)
    weekday_offset = Date.day_of_week(current_date) - 1
    start_of_week = current_date |> Date.add(-weekday_offset) |> Date.add(offset_weeks * 7)
    end_of_week = Date.add(start_of_week, 6)
    %{from: start_of_day(start_of_week), to: end_of_day(end_of_week)}
  end

  defp month_constraint(anchor, offset_months) do
    anchor_date = DateTime.to_date(anchor)
    shifted = shift_month(anchor_date, offset_months)
    start_of_month = %Date{year: shifted.year, month: shifted.month, day: 1}
    end_of_month = Date.end_of_month(start_of_month)
    %{from: start_of_day(start_of_month), to: end_of_day(end_of_month)}
  end

  defp shift_month(%Date{year: year, month: month} = date, delta) do
    zero_based = month - 1 + delta
    new_year = year + Integer.floor_div(zero_based, 12)
    new_month = Integer.mod(zero_based, 12) + 1
    max_day = Date.days_in_month(%Date{year: new_year, month: new_month, day: 1})
    %Date{date | year: new_year, month: new_month, day: min(date.day, max_day)}
  end

  defp start_of_day(%Date{} = date) do
    {:ok, datetime} = DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    datetime
  end

  defp end_of_day(%Date{} = date) do
    {:ok, datetime} = DateTime.new(date, ~T[23:59:59], "Etc/UTC")
    datetime
  end

  defp compare_after(unit, filter_value) do
    compare_datetime(unit["mentioned_at"], filter_value) in [:eq, :gt]
  end

  defp compare_before(unit, filter_value) do
    compare_datetime(unit["mentioned_at"], filter_value) in [:eq, :lt]
  end

  defp compare_datetime(left, right) do
    with {:ok, left_dt, _} <- DateTime.from_iso8601(left),
         {:ok, right_dt, _} <- DateTime.from_iso8601(right) do
      DateTime.compare(left_dt, right_dt)
    else
      _ -> :eq
    end
  end

  defp compare_datetimes_desc(nil), do: {1, ""}

  defp compare_datetimes_desc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {0, -DateTime.to_unix(datetime, :second)}
      _ -> {1, value}
    end
  end

  defp maybe_filter_fake_tag_pattern(items, nil), do: items
  defp maybe_filter_fake_tag_pattern(items, ""), do: items

  defp maybe_filter_fake_tag_pattern(items, pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> then(&Regex.compile!("^" <> &1 <> "$", "i"))

    Enum.filter(items, fn item -> Regex.match?(regex, item["tag"]) end)
  end

  defp fake_score(unit, query) do
    haystack = "#{unit["content"]} #{unit["context"]}" |> String.downcase()
    tokens = query_tokens(query)

    content_bonus =
      case tokens do
        [] -> 0.0
        _ -> Enum.count(tokens, &String.contains?(haystack, &1)) / length(tokens) * 0.15
      end

    tag_bonus = min(length(unit["tags"]), 5) * 0.01
    min(1.0, 0.8 + content_bonus + tag_bonus)
  end

  defp keyword_score(unit, query) do
    haystack = "#{unit["content"]} #{unit["context"]}" |> String.downcase()

    query
    |> keyword_terms()
    |> Enum.uniq()
    |> then(fn tokens ->
      case tokens do
        [] -> 0.0
        _ -> Enum.count(tokens, &String.contains?(haystack, &1)) / length(tokens)
      end
    end)
    |> Float.round(6)
  end

  defp temporal_query_score(unit, query) do
    haystack = "#{unit["content"]} #{unit["context"]}" |> String.downcase()

    query
    |> query_tokens()
    |> Enum.reject(
      &(&1 in ~w(what happened with when yesterday today tomorrow last next this that))
    )
    |> Enum.uniq()
    |> then(fn tokens ->
      case tokens do
        [] -> 0.0
        _ -> Enum.count(tokens, &String.contains?(haystack, &1)) / length(tokens)
      end
    end)
    |> Float.round(6)
  end

  defp graph_score(
         unit,
         query_entities,
         seed_ids,
         query,
         hop,
         seed_overlap,
         source_seed?,
         source_overlap_count,
         source_shortfall_bonus
       ) do
    memory_entities =
      unit["content"]
      |> EntityExtractor.extract()
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    shared_entity_count = Enum.count(query_entities, &(&1 in memory_entities))
    entity_score = :math.tanh(shared_entity_count * 0.5)
    semantic_score = semantic_link_score(unit, query)

    causal_score =
      if Enum.any?(unit["source_memory_ids"] || [], &MapSet.member?(seed_ids, &1)),
        do: 1.0,
        else: 0.0

    source_seed_score = if source_seed?, do: 1.0, else: 0.0
    source_link_score = min(source_overlap_count, 3) * 0.35
    overlap_bonus = min(length(seed_overlap), 3) * 0.1
    hop_decay = :math.pow(@graph_decay, hop)

    Float.round(
      (entity_score + semantic_score + causal_score + source_seed_score + source_link_score +
         overlap_bonus + source_shortfall_bonus) * hop_decay,
      6
    )
  end

  defp source_expansion_traversal_score(
         unit,
         query,
         hop,
         frontier_overlap_count,
         source_seed_overlap_count,
         source_expansion_context,
         source_shortfall_type
       ) do
    semantic_score = max(semantic_link_score(unit, query), 0.0)
    frontier_score = min(frontier_overlap_count, 3) * 0.5
    source_seed_score = min(source_seed_overlap_count, 3) * 0.75

    shortfall_bonus =
      source_expansion_shortfall_bonus(
        unit,
        source_expansion_context,
        source_shortfall_type
      )

    hop_decay = :math.pow(@graph_decay, hop)

    Float.round(
      (semantic_score + frontier_score + source_seed_score + shortfall_bonus) * hop_decay,
      6
    )
  end

  defp maybe_prioritize_source_expansion_frontier(
         items,
         false,
         remaining_budget,
         _source_expansion_context,
         _source_shortfall_type
       ),
       do: Enum.take(items, remaining_budget)

  defp maybe_prioritize_source_expansion_frontier(
         items,
         true,
         remaining_budget,
         source_expansion_context,
         source_shortfall_type
       ) do
    items
    |> prioritize_source_expansion_frontier(source_expansion_context, source_shortfall_type)
    |> Enum.take(remaining_budget)
  end

  defp prioritize_source_expansion_frontier(items, _context, nil) do
    Enum.sort_by(items, fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit["id"]}
    end)
  end

  defp prioritize_source_expansion_frontier(items, _context, "source_family") do
    items
    |> Enum.sort_by(fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit["id"]}
    end)
    |> take_distinct_frontier_groups(&source_expansion_document_family(&1.unit))
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        {-item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit["id"]}
      end)
    )
    |> Enum.uniq_by(& &1.unit["id"])
  end

  defp prioritize_source_expansion_frontier(items, _context, "raw_memory_breadth") do
    items
    |> Enum.sort_by(fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit["id"]}
    end)
    |> take_distinct_frontier_groups(&source_expansion_memory_family(&1.unit))
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        {-item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit["id"]}
      end)
    )
    |> Enum.uniq_by(& &1.unit["id"])
  end

  defp prioritize_source_expansion_frontier(items, context, "source_lineage") do
    items
    |> Enum.sort_by(fn item ->
      novel_lineage_sources =
        item.unit
        |> Map.get("source_memory_ids", [])
        |> MapSet.new()
        |> MapSet.difference(context.source_seed_ids)
        |> MapSet.size()

      {-novel_lineage_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit["id"]}
    end)
    |> take_distinct_frontier_groups(fn item ->
      get_in(item.frontier_evidence, ["group"])
    end)
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        novel_lineage_sources =
          item.unit
          |> Map.get("source_memory_ids", [])
          |> MapSet.new()
          |> MapSet.difference(context.source_seed_ids)
          |> MapSet.size()

        {-novel_lineage_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit["id"]}
      end)
    )
    |> Enum.uniq_by(& &1.unit["id"])
  end

  defp prioritize_source_expansion_frontier(items, context, "source_provenance") do
    items
    |> Enum.sort_by(fn item ->
      novel_sources =
        item.unit
        |> Map.get("source_memory_ids", [])
        |> MapSet.new()
        |> MapSet.difference(context.source_seed_ids)
        |> MapSet.size()

      {-novel_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit["id"]}
    end)
    |> take_distinct_frontier_groups(fn item ->
      get_in(item.frontier_evidence, ["group"])
    end)
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        novel_sources =
          item.unit
          |> Map.get("source_memory_ids", [])
          |> MapSet.new()
          |> MapSet.difference(context.source_seed_ids)
          |> MapSet.size()

        {-novel_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit["id"]}
      end)
    )
    |> Enum.uniq_by(& &1.unit["id"])
  end

  defp prioritize_source_expansion_frontier(items, _context, _source_shortfall_type) do
    Enum.sort_by(items, fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit["id"]}
    end)
  end

  defp take_distinct_frontier_groups(items, grouper) do
    {selected, _seen} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {selected, seen} ->
        case grouper.(item) do
          nil ->
            {[item | selected], seen}

          group when is_binary(group) ->
            if MapSet.member?(seen, group) do
              {selected, seen}
            else
              {[item | selected], MapSet.put(seen, group)}
            end
        end
      end)

    Enum.reverse(selected)
  end

  defp semantic_link_score(unit, query) do
    similarity = fake_score(unit, query)
    if similarity >= @graph_semantic_floor, do: similarity, else: 0.0
  end

  defp temporal_runtime_score(unit, constraint, query_timestamp) do
    base_score = temporal_score(unit, constraint, query_timestamp)
    source_overlap = unit["temporal_source_overlap"] || []
    seed_score = Map.get(unit, "temporal_seed_score", 0.0)
    overlap_bonus = Map.get(unit, "temporal_overlap_bonus", 0.0)
    hop = Map.get(unit, "temporal_hop", 0)
    hop_decay = :math.pow(@temporal_decay, max(hop - 1, 0))
    link_boost = if source_overlap != [], do: @temporal_link_boost, else: @temporal_entry_boost
    Float.round(base_score * link_boost * hop_decay + seed_score + overlap_bonus, 6)
  end

  # Same precedence as Storage.Ecto's temporal scoring and window filter: the
  # event time (occurred_end, then occurred_start, then occurred_at) beats the
  # time the memory was mentioned.
  defp unit_datetime(unit) do
    (unit["occurred_end"] || unit["occurred_start"] || unit["occurred_at"] || unit["mentioned_at"])
    |> to_datetime()
  end

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(value) when is_binary(value), do: parse_query_timestamp(value)
  defp to_datetime(_other), do: nil

  defp temporal_score(unit, constraint, query_timestamp) do
    timestamp = unit_datetime(unit)

    anchor =
      DateTime.add(
        constraint.from,
        div(DateTime.diff(constraint.to, constraint.from), 2),
        :second
      )

    cond do
      is_nil(timestamp) ->
        0.0

      true ->
        delta_days = abs(DateTime.diff(timestamp, anchor, :day))
        base = if delta_days == 0, do: 1.0, else: 1.0 / (delta_days + 1)
        if query_timestamp, do: Float.round(base, 6), else: Float.round(base * 0.9, 6)
    end
  end

  defp query_tokens(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(&1 in ["what", "did", "say", "about", "the", "a", "an", "of", "to", "in"]))
  end

  defp keyword_terms(query) do
    stopwords =
      MapSet.new(~w(
        a an about after all and are as at because before but by did do does for from
        had has have how i if in into is it just more not of on or our over
        real reason simply that the their then there these they this to was we were what
        when where which who why with would yesterday today tomorrow
      ))

    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(stopwords, &1)))
    |> Enum.uniq()
  end

  defp apply_recall_boost_multiplier(score, multiplier)
       when is_number(score) and is_number(multiplier) and score < 0.0 do
    score / max(multiplier, 1.0e-6)
  end

  defp apply_recall_boost_multiplier(score, multiplier)
       when is_number(score) and is_number(multiplier) do
    score * multiplier
  end

  defp semantic_overlap_threshold(tokens) do
    case length(tokens) do
      0 -> 1
      1 -> 1
      _ -> 2
    end
  end

  defp canonical_pairs(entity_ids) do
    entity_ids
    |> Enum.uniq()
    |> Enum.sort()
    |> then(fn ids ->
      for source <- ids,
          target <- ids,
          source < target do
        {source, target}
      end
    end)
  end

  defp trim_units_to_token_budget(units, max_tokens)
       when is_integer(max_tokens) and max_tokens > 0 do
    units
    |> Enum.reduce_while({[], 0}, fn unit, {kept, used_tokens} ->
      {:ok, token_count} = Budget.count_tokens(unit["content"])

      cond do
        used_tokens + token_count <= max_tokens ->
          {:cont, {[unit | kept], used_tokens + token_count}}

        kept == [] ->
          {:halt, {[], 0}}

        true ->
          {:halt, {kept, used_tokens}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp trim_units_to_token_budget(units, _max_tokens), do: units

  defp run_reflect_loop(
         ctx,
         payload,
         opts,
         llm,
         bank_profile,
         directives,
         recall_result,
         mental_models,
         plan,
         initial_plan_prompt,
         observations,
         max_iterations
       ) do
    {expanded_recall_results, expand_tool_call} =
      maybe_expand_reflect_results(ctx.bank, recall_result["results"], payload, max_iterations)

    recall_result = Map.put(recall_result, "results", expanded_recall_results)

    initial_tool_calls = [
      %{
        "iteration" => 1,
        "phase" => "forced_initial_recall",
        "tool" => "recall",
        "query" => plan.focus_query,
        "result_count" => length(recall_result["results"]),
        "input" => %{
          "query" => plan.focus_query,
          "payload" => Map.take(payload, ["tags", "query_timestamp"])
        },
        "output" => %{"result_ids" => Enum.map(recall_result["results"], & &1["id"])}
      }
    ]

    observation_tool_call = %{
      "iteration" => 2,
      "phase" => "forced_observations",
      "tool" => "search_observations",
      "type" => "observation",
      "result_count" => length(observations["observations"]),
      "input" => %{
        "type" => "observation",
        "tags" => payload["tags"],
        "scope_keys" => reflect_scope_keys(payload)
      },
      "output" => Map.drop(observations, ["observations"])
    }

    initial_plan_events = [
      %{"phase" => "plan", "prompt" => initial_plan_prompt, "output" => plan}
    ]

    if plan.needs_consolidation do
      with {:ok, _} <- consolidate(ctx, consolidation_payload(payload), opts),
           {:ok, refreshed_recall} <-
             recall(ctx, Map.put(payload, "query", plan.focus_query), opts) do
        {expanded_refreshed_results, refreshed_expand_tool_call} =
          maybe_expand_reflect_results(
            ctx.bank,
            refreshed_recall["results"],
            payload,
            max_iterations + 2
          )

        refreshed_recall = Map.put(refreshed_recall, "results", expanded_refreshed_results)
        refreshed_observations = reflect_observations(ctx, payload)

        {:ok,
         %{
           recall_result: refreshed_recall,
           grounded_results:
             merge_grounding_results(
               refreshed_observations["observations"],
               refreshed_recall["results"]
             ),
           observations: refreshed_observations,
           mental_models: active_mental_models(ctx.bank, payload),
           current_plan: plan,
           plan_events: initial_plan_events,
           termination:
             reflect_termination(
               "consolidated",
               plan.reason || "initial consolidation complete",
               6
             ),
           tool_calls:
             initial_tool_calls ++
               [observation_tool_call] ++
               maybe_list(expand_tool_call) ++
               [
                 %{
                   "iteration" => 4,
                   "phase" => "auto_consolidate",
                   "tool" => "consolidate",
                   "scope_keys" => requested_scopes(consolidation_payload(payload)),
                   "input" => consolidation_payload(payload),
                   "output" => %{"status" => "ok"}
                 },
                 %{
                   "iteration" => 5,
                   "phase" => "forced_final_recall",
                   "tool" => "recall",
                   "query" => plan.focus_query,
                   "result_count" => length(refreshed_recall["results"]),
                   "input" => %{"query" => plan.focus_query},
                   "output" => %{
                     "result_ids" => Enum.map(refreshed_recall["results"], & &1["id"])
                   }
                 }
               ] ++
               maybe_list(refreshed_expand_tool_call) ++
               [
                 %{
                   "iteration" => 6,
                   "phase" => "forced_final_observations",
                   "tool" => "search_observations",
                   "type" => "observation",
                   "result_count" => length(refreshed_observations["observations"]),
                   "input" => %{
                     "type" => "observation",
                     "tags" => payload["tags"],
                     "scope_keys" => reflect_scope_keys(payload)
                   },
                   "output" => Map.drop(refreshed_observations, ["observations"])
                 }
               ]
         }}
      end
    else
      {:ok,
       %{
         recall_result: recall_result,
         grounded_results:
           merge_grounding_results(observations["observations"], recall_result["results"]),
         observations: observations,
         mental_models: mental_models,
         current_plan: plan,
         plan_events: initial_plan_events,
         termination:
           initial_reflect_termination(
             payload,
             plan,
             max_iterations,
             "initial planner result"
           ),
         tool_calls:
           initial_tool_calls ++
             [observation_tool_call] ++
             maybe_list(expand_tool_call) ++
             [
               %{
                 "iteration" => 4,
                 "phase" => "auto_consolidate",
                 "tool" => "consolidate",
                 "skipped" => true,
                 "reason" => plan.reason,
                 "input" => consolidation_payload(payload)
               }
             ]
       }}
      |> maybe_run_verification_recall(
        ctx,
        payload,
        opts,
        llm,
        bank_profile,
        directives,
        plan,
        max_iterations
      )
    end
  end

  defp maybe_run_verification_recall(
         {:ok,
          %{
            recall_result: recall_result,
            grounded_results: grounded_results,
            observations: observations,
            mental_models: mental_models,
            current_plan: current_plan,
            plan_events: plan_events,
            termination: _termination,
            tool_calls: tool_calls
          }},
         ctx,
         payload,
         opts,
         llm,
         bank_profile,
         directives,
         plan,
         max_iterations
       ) do
    should_verify? =
      not plan.needs_consolidation and not plan.answer_ready and max_iterations > 1 and
        is_binary(plan.focus_query) and String.trim(plan.focus_query) != "" and
        plan.focus_query != payload["query"]

    if should_verify? do
      with {:ok, verification_recall} <-
             recall(ctx, Map.put(payload, "query", plan.focus_query), opts) do
        {expanded_verification_results, verification_expand_tool_call} =
          maybe_expand_reflect_results(
            ctx.bank,
            verification_recall["results"],
            payload,
            max_iterations + 1
          )

        merged_results =
          merge_reflect_recall_results(recall_result["results"], expanded_verification_results)

        verification_recall = Map.put(recall_result, "results", merged_results)

        updated_grounded_results =
          merge_grounding_results(observations["observations"], merged_results)

        verification_progress? =
          verification_results_progress?(
            grounded_results,
            updated_grounded_results,
            recall_result["results"],
            expanded_verification_results,
            mental_models,
            opts
          )

        {:ok,
         %{
           recall_result: verification_recall,
           grounded_results: updated_grounded_results,
           observations: observations,
           mental_models: mental_models,
           current_plan: plan,
           plan_events: plan_events,
           termination:
             reflect_termination(
               if(verification_progress?,
                 do: "verification_progress",
                 else: "verification_no_progress"
               ),
               if(
                 verification_progress?,
                 do: plan.reason || "verification recall completed",
                 else: "verification recall did not improve grounding"
               ),
               5
             ),
           tool_calls:
             tool_calls ++
               [
                 %{
                   "iteration" => 5,
                   "phase" => "verification_recall",
                   "tool" => "recall",
                   "query" => plan.focus_query,
                   "result_count" => length(expanded_verification_results),
                   "input" => %{"query" => plan.focus_query},
                   "output" => %{
                     "result_ids" => Enum.map(expanded_verification_results, & &1["id"])
                   }
                 }
               ] ++ maybe_list(verification_expand_tool_call)
         }}
        |> then(fn result ->
          if verification_progress? do
            maybe_replan_after_verification(
              result,
              ctx,
              payload,
              opts,
              llm,
              bank_profile,
              directives,
              previous_plan: plan,
              seen_queries: [payload["query"], plan.focus_query],
              verification_index: 2,
              iteration: 6,
              remaining_replans: max_iterations - 3
            )
          else
            result
          end
        end)
      end
    else
      {:ok,
       %{
         recall_result: recall_result,
         grounded_results: grounded_results,
         observations: observations,
         mental_models: mental_models,
         current_plan: current_plan,
         plan_events: plan_events,
         termination:
           reflect_termination(
             verification_skip_status(plan, payload, max_iterations),
             verification_skip_reason(plan, payload, max_iterations),
             4
           ),
         tool_calls: tool_calls
       }}
    end
  end

  defp maybe_replan_for_evidence_breadth(
         {:ok,
          %{
            recall_result: recall_result,
            grounded_results: grounded_results,
            observations: observations,
            mental_models: mental_models,
            current_plan: current_plan,
            plan_events: plan_events,
            termination: termination,
            tool_calls: tool_calls
          }},
         ctx,
         payload,
         opts,
         llm,
         bank_profile,
         directives,
         max_iterations
       ) do
    available_evidence_discipline =
      available_reflect_evidence_discipline(
        grounded_results,
        mental_models,
        opts
      )

    should_replan? =
      current_plan.answer_ready and
        evidence_discipline_replan?(available_evidence_discipline) and
        termination["iteration"] < max_iterations

    if should_replan? do
      replan_prompt =
        Foresight.Prompts.Reflect.Plan.V1.build(
          payload["query"],
          payload,
          bank_profile,
          recall_result["results"],
          observations,
          directives,
          mental_models
        )
        |> Map.put(
          :evidence_shortfall,
          reflect_evidence_shortfall_prompt(available_evidence_discipline)
        )

      with {:ok, replan} <-
             llm.complete_structured(
               replan_prompt,
               [],
               Foresight.Prompts.ReflectPlanResponse,
               opts
             ) do
        replan_events =
          plan_events ++
            [
              %{
                "phase" => "evidence_breadth_replan",
                "prompt" => replan_prompt,
                "output" => replan
              }
            ]

        seen_queries = reflect_seen_queries(tool_calls, payload["query"])
        next_iteration = termination["iteration"] + 1

        verification_payload =
          reflect_evidence_verification_payload(
            payload,
            replan.focus_query,
            available_evidence_discipline,
            replan.refinement_intent
          )

        should_verify? =
          not replan.needs_consolidation and not replan.answer_ready and
            is_binary(replan.focus_query) and String.trim(replan.focus_query) != "" and
            replan.focus_query not in seen_queries and next_iteration <= max_iterations

        if should_verify? do
          with {:ok, verification_recall} <-
                 recall(ctx, verification_payload, opts) do
            merged_results =
              merge_reflect_recall_results(
                recall_result["results"],
                verification_recall["results"]
              )

            merged_grounded_results =
              merge_grounding_results(observations["observations"], merged_results)

            updated_evidence_discipline =
              available_reflect_evidence_discipline(
                merged_grounded_results,
                mental_models,
                opts
              )

            progress? =
              evidence_discipline_progress?(
                available_evidence_discipline,
                updated_evidence_discipline
              )

            verification_tool_calls =
              tool_calls ++
                [
                  %{
                    "iteration" => next_iteration,
                    "phase" => "evidence_breadth_verification_recall",
                    "tool" => "recall",
                    "query" => replan.focus_query,
                    "result_count" => length(verification_recall["results"]),
                    "input" => %{
                      "query" => replan.focus_query,
                      "payload" =>
                        Map.take(verification_payload, [
                          "budget",
                          "tags",
                          "types",
                          "query_timestamp",
                          "verification_mode",
                          "source_shortfall_type",
                          "source_novel_only"
                        ])
                    },
                    "output" => %{
                      "result_ids" => Enum.map(verification_recall["results"], & &1["id"]),
                      "evidence_progress" => progress?,
                      "evidence_status" => updated_evidence_discipline["status"]
                    }
                  }
                ]

            cond do
              not progress? and
                  planner_directed_memory_retry_after_source?(
                    replan,
                    verification_payload,
                    next_iteration,
                    max_iterations
                  ) ->
                memory_retry_payload =
                  broaden_memory_breadth_payload(verification_payload, replan.focus_query)

                with {:ok, memory_retry_recall} <-
                       recall(ctx, memory_retry_payload, opts) do
                  memory_retry_merged_results =
                    merge_reflect_recall_results(
                      merged_results,
                      memory_retry_recall["results"]
                    )

                  memory_retry_grounded_results =
                    merge_grounding_results(
                      observations["observations"],
                      memory_retry_merged_results
                    )

                  memory_retry_evidence_discipline =
                    available_reflect_evidence_discipline(
                      memory_retry_grounded_results,
                      mental_models,
                      opts
                    )

                  memory_retry_progress? =
                    evidence_discipline_progress?(
                      available_evidence_discipline,
                      memory_retry_evidence_discipline
                    )

                  memory_retry_tool_calls =
                    verification_tool_calls ++
                      [
                        %{
                          "iteration" => next_iteration + 1,
                          "phase" => "evidence_breadth_memory_retry_recall",
                          "tool" => "recall",
                          "query" => memory_retry_payload["query"],
                          "result_count" => length(memory_retry_recall["results"]),
                          "input" => %{
                            "query" => memory_retry_payload["query"],
                            "payload" =>
                              Map.take(memory_retry_payload, [
                                "budget",
                                "tags",
                                "types",
                                "query_timestamp",
                                "verification_mode"
                              ])
                          },
                          "output" => %{
                            "result_ids" => Enum.map(memory_retry_recall["results"], & &1["id"]),
                            "evidence_progress" => memory_retry_progress?,
                            "evidence_status" => memory_retry_evidence_discipline["status"]
                          }
                        }
                      ]

                  {:ok,
                   %{
                     recall_result:
                       Map.put(recall_result, "results", memory_retry_merged_results),
                     grounded_results: memory_retry_grounded_results,
                     observations: observations,
                     mental_models: mental_models,
                     current_plan: replan,
                     plan_events: replan_events,
                     termination:
                       reflect_termination(
                         if(memory_retry_progress?,
                           do: evidence_breadth_progress_status(available_evidence_discipline),
                           else:
                             evidence_breadth_no_progress_status(available_evidence_discipline)
                         ),
                         if(memory_retry_progress?,
                           do:
                             "planner-directed source-linked verification followed by memory retry improved raw-memory breadth",
                           else:
                             "planner-directed source-linked verification followed by memory retry did not improve raw-memory breadth"
                         ),
                         next_iteration + 1
                       ),
                     tool_calls: memory_retry_tool_calls
                   }}
                end

              not progress? and
                  direct_memory_source_refinement?(replan, verification_payload) ->
                {:ok,
                 %{
                   recall_result: Map.put(recall_result, "results", merged_results),
                   grounded_results: merged_grounded_results,
                   observations: observations,
                   mental_models: mental_models,
                   current_plan: replan,
                   plan_events: replan_events,
                   termination:
                     reflect_termination(
                       evidence_breadth_no_progress_status(available_evidence_discipline),
                       "planner-directed source-linked memory verification did not improve raw-memory breadth",
                       next_iteration
                     ),
                   tool_calls: verification_tool_calls
                 }}

              not progress? and
                  evidence_breadth_memory_retry?(
                    available_evidence_discipline,
                    verification_payload,
                    next_iteration,
                    max_iterations
                  ) ->
                memory_retry_payload =
                  broaden_memory_breadth_payload(verification_payload, replan.focus_query)

                with {:ok, memory_retry_recall} <-
                       recall(ctx, memory_retry_payload, opts) do
                  memory_retry_merged_results =
                    merge_reflect_recall_results(
                      merged_results,
                      memory_retry_recall["results"]
                    )

                  memory_retry_grounded_results =
                    merge_grounding_results(
                      observations["observations"],
                      memory_retry_merged_results
                    )

                  memory_retry_evidence_discipline =
                    available_reflect_evidence_discipline(
                      memory_retry_grounded_results,
                      mental_models,
                      opts
                    )

                  memory_retry_progress? =
                    evidence_discipline_progress?(
                      available_evidence_discipline,
                      memory_retry_evidence_discipline
                    )

                  memory_retry_tool_calls =
                    verification_tool_calls ++
                      [
                        %{
                          "iteration" => next_iteration + 1,
                          "phase" => "evidence_breadth_memory_retry_recall",
                          "tool" => "recall",
                          "query" => memory_retry_payload["query"],
                          "result_count" => length(memory_retry_recall["results"]),
                          "input" => %{
                            "query" => memory_retry_payload["query"],
                            "payload" =>
                              Map.take(memory_retry_payload, [
                                "budget",
                                "tags",
                                "types",
                                "query_timestamp",
                                "verification_mode"
                              ])
                          },
                          "output" => %{
                            "result_ids" => Enum.map(memory_retry_recall["results"], & &1["id"]),
                            "evidence_progress" => memory_retry_progress?,
                            "evidence_status" => memory_retry_evidence_discipline["status"]
                          }
                        }
                      ]

                  cond do
                    not memory_retry_progress? and
                        evidence_breadth_memory_source_retry?(
                          available_evidence_discipline,
                          next_iteration + 1,
                          max_iterations
                        ) ->
                      memory_source_retry_payload =
                        broaden_memory_source_payload(memory_retry_payload, replan.focus_query)

                      with {:ok, memory_source_retry_recall} <-
                             recall(ctx, memory_source_retry_payload, opts) do
                        memory_source_retry_merged_results =
                          merge_reflect_recall_results(
                            memory_retry_merged_results,
                            memory_source_retry_recall["results"]
                          )

                        memory_source_retry_grounded_results =
                          merge_grounding_results(
                            observations["observations"],
                            memory_source_retry_merged_results
                          )

                        memory_source_retry_evidence_discipline =
                          available_reflect_evidence_discipline(
                            memory_source_retry_grounded_results,
                            mental_models,
                            opts
                          )

                        memory_source_retry_progress? =
                          evidence_discipline_progress?(
                            available_evidence_discipline,
                            memory_source_retry_evidence_discipline
                          )

                        memory_source_retry_tool_calls =
                          memory_retry_tool_calls ++
                            [
                              %{
                                "iteration" => next_iteration + 2,
                                "phase" => "evidence_breadth_memory_source_retry_recall",
                                "tool" => "recall",
                                "query" => memory_source_retry_payload["query"],
                                "result_count" => length(memory_source_retry_recall["results"]),
                                "input" => %{
                                  "query" => memory_source_retry_payload["query"],
                                  "payload" =>
                                    Map.take(memory_source_retry_payload, [
                                      "budget",
                                      "tags",
                                      "types",
                                      "query_timestamp",
                                      "verification_mode",
                                      "source_shortfall_type"
                                    ])
                                },
                                "output" => %{
                                  "result_ids" =>
                                    Enum.map(memory_source_retry_recall["results"], & &1["id"]),
                                  "evidence_progress" => memory_source_retry_progress?,
                                  "evidence_status" =>
                                    memory_source_retry_evidence_discipline["status"]
                                }
                              }
                            ]

                        {:ok,
                         %{
                           recall_result:
                             Map.put(
                               recall_result,
                               "results",
                               memory_source_retry_merged_results
                             ),
                           grounded_results: memory_source_retry_grounded_results,
                           observations: observations,
                           mental_models: mental_models,
                           current_plan: replan,
                           plan_events: replan_events,
                           termination:
                             reflect_termination(
                               if(memory_source_retry_progress?,
                                 do:
                                   evidence_breadth_progress_status(available_evidence_discipline),
                                 else:
                                   evidence_breadth_no_progress_status(
                                     available_evidence_discipline
                                   )
                               ),
                               if(memory_source_retry_progress?,
                                 do: "memory-breadth source retry improved raw-memory breadth",
                                 else:
                                   "memory-breadth source retry did not improve raw-memory breadth"
                               ),
                               next_iteration + 2
                             ),
                           tool_calls: memory_source_retry_tool_calls
                         }}
                      end

                    true ->
                      {:ok,
                       %{
                         recall_result:
                           Map.put(recall_result, "results", memory_retry_merged_results),
                         grounded_results: memory_retry_grounded_results,
                         observations: observations,
                         mental_models: mental_models,
                         current_plan: replan,
                         plan_events: replan_events,
                         termination:
                           reflect_termination(
                             if(memory_retry_progress?,
                               do:
                                 evidence_breadth_progress_status(available_evidence_discipline),
                               else:
                                 evidence_breadth_no_progress_status(
                                   available_evidence_discipline
                                 )
                             ),
                             if(memory_retry_progress?,
                               do: "memory-breadth retry improved raw-memory breadth",
                               else: "memory-breadth retry did not improve raw-memory breadth"
                             ),
                             next_iteration + 1
                           ),
                         tool_calls: memory_retry_tool_calls
                       }}
                  end
                end

              not progress? and
                  evidence_breadth_consolidation_retry?(
                    available_evidence_discipline,
                    payload,
                    next_iteration,
                    max_iterations
                  ) ->
                with {:ok, _} <- consolidate(ctx, consolidation_payload(payload), opts) do
                  refreshed_observations = reflect_observations(ctx, payload)
                  refreshed_mental_models = active_mental_models(ctx.bank, payload)

                  consolidated_grounded_results =
                    merge_grounding_results(
                      refreshed_observations["observations"],
                      merged_results
                    )

                  consolidated_evidence_discipline =
                    available_reflect_evidence_discipline(
                      consolidated_grounded_results,
                      refreshed_mental_models,
                      opts
                    )

                  consolidated_progress? =
                    evidence_discipline_progress?(
                      available_evidence_discipline,
                      consolidated_evidence_discipline
                    )

                  {:ok,
                   %{
                     recall_result: Map.put(recall_result, "results", merged_results),
                     grounded_results: consolidated_grounded_results,
                     observations: refreshed_observations,
                     mental_models: refreshed_mental_models,
                     current_plan: replan,
                     plan_events: replan_events,
                     termination:
                       reflect_termination(
                         if(consolidated_progress?,
                           do: evidence_breadth_progress_status(available_evidence_discipline),
                           else:
                             evidence_breadth_no_progress_status(available_evidence_discipline)
                         ),
                         if(consolidated_progress?,
                           do:
                             evidence_breadth_consolidation_progress_reason(
                               available_evidence_discipline,
                               "consolidation improved evidence breadth"
                             ),
                           else:
                             evidence_breadth_consolidation_no_progress_reason(
                               available_evidence_discipline,
                               "consolidation did not improve evidence breadth"
                             )
                         ),
                         next_iteration + 1
                       ),
                     tool_calls:
                       verification_tool_calls ++
                         [
                           %{
                             "iteration" => next_iteration + 1,
                             "phase" => "evidence_breadth_consolidate",
                             "tool" => "consolidate",
                             "scope_keys" => reflect_scope_keys(payload),
                             "input" => consolidation_payload(payload),
                             "output" => %{
                               "status" => "ok",
                               "evidence_progress" => consolidated_progress?,
                               "evidence_status" => consolidated_evidence_discipline["status"]
                             }
                           },
                           %{
                             "iteration" => next_iteration + 1,
                             "phase" => "evidence_breadth_post_consolidation_observations",
                             "tool" => "search_observations",
                             "result_count" => length(refreshed_observations["observations"]),
                             "input" => %{
                               "type" => "observation",
                               "tags" => payload["tags"],
                               "scope_keys" => reflect_scope_keys(payload)
                             },
                             "output" => Map.drop(refreshed_observations, ["observations"])
                           }
                         ]
                   }}
                end

              not progress? and
                  evidence_breadth_source_retry?(
                    available_evidence_discipline,
                    verification_payload,
                    next_iteration,
                    max_iterations
                  ) ->
                source_retry_payload =
                  broaden_source_expansion_payload(
                    verification_payload,
                    replan.focus_query,
                    available_evidence_discipline
                  )

                with {:ok, source_retry_recall} <-
                       recall(ctx, source_retry_payload, opts) do
                  source_retry_merged_results =
                    merge_reflect_recall_results(
                      merged_results,
                      source_retry_recall["results"]
                    )

                  source_retry_grounded_results =
                    merge_grounding_results(
                      observations["observations"],
                      source_retry_merged_results
                    )

                  source_retry_evidence_discipline =
                    available_reflect_evidence_discipline(
                      source_retry_grounded_results,
                      mental_models,
                      opts
                    )

                  source_retry_progress? =
                    evidence_discipline_progress?(
                      available_evidence_discipline,
                      source_retry_evidence_discipline
                    )

                  source_retry_tool_calls =
                    verification_tool_calls ++
                      [
                        %{
                          "iteration" => next_iteration + 1,
                          "phase" => "evidence_breadth_source_retry_recall",
                          "tool" => "recall",
                          "query" => source_retry_payload["query"],
                          "result_count" => length(source_retry_recall["results"]),
                          "input" => %{
                            "query" => source_retry_payload["query"],
                            "payload" =>
                              Map.take(source_retry_payload, [
                                "budget",
                                "source_shortfall_type",
                                "tags",
                                "query_timestamp",
                                "verification_mode",
                                "source_novel_only"
                              ])
                          },
                          "output" => %{
                            "result_ids" => Enum.map(source_retry_recall["results"], & &1["id"]),
                            "evidence_progress" => source_retry_progress?,
                            "evidence_status" => source_retry_evidence_discipline["status"]
                          }
                        }
                      ]

                  cond do
                    not source_retry_progress? and
                        evidence_breadth_source_consolidation_retry?(
                          available_evidence_discipline,
                          payload,
                          next_iteration + 1,
                          max_iterations
                        ) ->
                      with {:ok, _} <- consolidate(ctx, consolidation_payload(payload), opts) do
                        refreshed_observations = reflect_observations(ctx, payload)
                        refreshed_mental_models = active_mental_models(ctx.bank, payload)

                        consolidated_grounded_results =
                          merge_grounding_results(
                            refreshed_observations["observations"],
                            source_retry_merged_results
                          )

                        consolidated_evidence_discipline =
                          available_reflect_evidence_discipline(
                            consolidated_grounded_results,
                            refreshed_mental_models,
                            opts
                          )

                        consolidated_progress? =
                          evidence_discipline_progress?(
                            available_evidence_discipline,
                            consolidated_evidence_discipline
                          )

                        {:ok,
                         %{
                           recall_result:
                             Map.put(recall_result, "results", source_retry_merged_results),
                           grounded_results: consolidated_grounded_results,
                           observations: refreshed_observations,
                           mental_models: refreshed_mental_models,
                           current_plan: replan,
                           plan_events: replan_events,
                           termination:
                             reflect_termination(
                               if(consolidated_progress?,
                                 do:
                                   evidence_breadth_progress_status(available_evidence_discipline),
                                 else:
                                   evidence_breadth_no_progress_status(
                                     available_evidence_discipline
                                   )
                               ),
                               if(consolidated_progress?,
                                 do:
                                   evidence_breadth_consolidation_progress_reason(
                                     available_evidence_discipline,
                                     "source-expansion retry consolidation improved evidence breadth"
                                   ),
                                 else:
                                   evidence_breadth_consolidation_no_progress_reason(
                                     available_evidence_discipline,
                                     "source-expansion retry consolidation did not improve evidence breadth"
                                   )
                               ),
                               next_iteration + 2
                             ),
                           tool_calls:
                             source_retry_tool_calls ++
                               [
                                 %{
                                   "iteration" => next_iteration + 2,
                                   "phase" => "evidence_breadth_source_consolidate",
                                   "tool" => "consolidate",
                                   "scope_keys" =>
                                     requested_scopes(consolidation_payload(payload)),
                                   "input" => consolidation_payload(payload),
                                   "output" => %{
                                     "status" => "ok",
                                     "evidence_progress" => consolidated_progress?,
                                     "evidence_status" =>
                                       consolidated_evidence_discipline["status"]
                                   }
                                 },
                                 %{
                                   "iteration" => next_iteration + 2,
                                   "phase" =>
                                     "evidence_breadth_source_post_consolidation_observations",
                                   "tool" => "search_observations",
                                   "result_count" =>
                                     length(refreshed_observations["observations"]),
                                   "input" => %{
                                     "type" => "observation",
                                     "tags" => payload["tags"],
                                     "scope_keys" => reflect_scope_keys(payload)
                                   },
                                   "output" => Map.drop(refreshed_observations, ["observations"])
                                 }
                               ]
                         }}
                      end

                    not source_retry_progress? and
                        evidence_breadth_source_consolidation_skip?(available_evidence_discipline) ->
                      {:ok,
                       %{
                         recall_result:
                           Map.put(recall_result, "results", source_retry_merged_results),
                         grounded_results: source_retry_grounded_results,
                         observations: observations,
                         mental_models: mental_models,
                         current_plan: replan,
                         plan_events: replan_events,
                         termination:
                           reflect_termination(
                             evidence_breadth_no_progress_status(available_evidence_discipline),
                             "source-expansion retry did not improve raw source provenance breadth",
                             next_iteration + 1
                           ),
                         tool_calls:
                           source_retry_tool_calls ++
                             [
                               %{
                                 "iteration" => next_iteration + 1,
                                 "phase" => "evidence_breadth_source_consolidation_skipped",
                                 "tool" => "consolidate",
                                 "scope_keys" => requested_scopes(consolidation_payload(payload)),
                                 "input" => consolidation_payload(payload),
                                 "output" => %{
                                   "status" => "skipped",
                                   "reason" => "raw_source_provenance_required"
                                 }
                               }
                             ]
                       }}

                    true ->
                      {:ok,
                       %{
                         recall_result:
                           Map.put(recall_result, "results", source_retry_merged_results),
                         grounded_results: source_retry_grounded_results,
                         observations: observations,
                         mental_models: mental_models,
                         current_plan: replan,
                         plan_events: replan_events,
                         termination:
                           reflect_termination(
                             if(source_retry_progress?,
                               do:
                                 evidence_breadth_progress_status(available_evidence_discipline),
                               else:
                                 evidence_breadth_no_progress_status(
                                   available_evidence_discipline
                                 )
                             ),
                             if(source_retry_progress?,
                               do:
                                 evidence_breadth_retry_progress_reason(
                                   available_evidence_discipline
                                 ),
                               else:
                                 evidence_breadth_retry_no_progress_reason(
                                   available_evidence_discipline
                                 )
                             ),
                             next_iteration + 1
                           ),
                         tool_calls: source_retry_tool_calls
                       }}
                  end
                end

              true ->
                {:ok,
                 %{
                   recall_result: Map.put(recall_result, "results", merged_results),
                   grounded_results: merged_grounded_results,
                   observations: observations,
                   mental_models: mental_models,
                   current_plan: replan,
                   plan_events: replan_events,
                   termination:
                     reflect_termination(
                       if(progress?,
                         do: evidence_breadth_progress_status(available_evidence_discipline),
                         else: evidence_breadth_no_progress_status(available_evidence_discipline)
                       ),
                       if(progress?,
                         do:
                           evidence_breadth_progress_reason(
                             available_evidence_discipline,
                             replan.reason
                           ),
                         else: evidence_breadth_no_progress_reason(available_evidence_discipline)
                       ),
                       next_iteration
                     ),
                   tool_calls: verification_tool_calls
                 }}
            end
          end
        else
          cond do
            planner_directed_source_consolidation?(
              replan,
              available_evidence_discipline,
              payload,
              next_iteration,
              max_iterations
            ) ->
              with {:ok, _} <- consolidate(ctx, consolidation_payload(payload), opts) do
                refreshed_observations = reflect_observations(ctx, payload)
                refreshed_mental_models = active_mental_models(ctx.bank, payload)

                consolidated_grounded_results =
                  merge_grounding_results(
                    refreshed_observations["observations"],
                    recall_result["results"]
                  )

                consolidated_evidence_discipline =
                  available_reflect_evidence_discipline(
                    consolidated_grounded_results,
                    refreshed_mental_models,
                    opts
                  )

                consolidated_progress? =
                  if source_consolidation_requires_retry?(available_evidence_discipline) do
                    false
                  else
                    evidence_discipline_progress?(
                      available_evidence_discipline,
                      consolidated_evidence_discipline
                    )
                  end

                consolidation_tool_calls =
                  tool_calls ++
                    [
                      %{
                        "iteration" => next_iteration,
                        "phase" => "evidence_breadth_source_consolidate",
                        "tool" => "consolidate",
                        "scope_keys" => reflect_scope_keys(payload),
                        "input" => consolidation_payload(payload),
                        "output" => %{
                          "status" => "ok",
                          "evidence_progress" => consolidated_progress?,
                          "evidence_status" => consolidated_evidence_discipline["status"]
                        }
                      },
                      %{
                        "iteration" => next_iteration,
                        "phase" => "evidence_breadth_source_post_consolidation_observations",
                        "tool" => "search_observations",
                        "result_count" => length(refreshed_observations["observations"]),
                        "input" => %{
                          "type" => "observation",
                          "tags" => payload["tags"],
                          "scope_keys" => reflect_scope_keys(payload)
                        },
                        "output" => Map.drop(refreshed_observations, ["observations"])
                      }
                    ]

                cond do
                  not consolidated_progress? and
                      evidence_breadth_source_retry?(
                        available_evidence_discipline,
                        payload,
                        next_iteration,
                        max_iterations
                      ) ->
                    source_retry_payload =
                      broaden_source_expansion_payload(
                        payload,
                        replan.focus_query,
                        available_evidence_discipline
                      )

                    with {:ok, source_retry_recall} <- recall(ctx, source_retry_payload, opts) do
                      source_retry_merged_results =
                        merge_reflect_recall_results(
                          recall_result["results"],
                          source_retry_recall["results"]
                        )

                      source_retry_grounded_results =
                        merge_grounding_results(
                          refreshed_observations["observations"],
                          source_retry_merged_results
                        )

                      source_retry_evidence_discipline =
                        available_reflect_evidence_discipline(
                          source_retry_grounded_results,
                          refreshed_mental_models,
                          opts
                        )

                      source_retry_progress? =
                        evidence_discipline_progress?(
                          consolidated_evidence_discipline,
                          source_retry_evidence_discipline
                        )

                      {:ok,
                       %{
                         recall_result:
                           Map.put(recall_result, "results", source_retry_merged_results),
                         grounded_results: source_retry_grounded_results,
                         observations: refreshed_observations,
                         mental_models: refreshed_mental_models,
                         current_plan: replan,
                         plan_events: replan_events,
                         termination:
                           reflect_termination(
                             if(source_retry_progress?,
                               do:
                                 evidence_breadth_progress_status(available_evidence_discipline),
                               else:
                                 evidence_breadth_no_progress_status(
                                   available_evidence_discipline
                                 )
                             ),
                             if(source_retry_progress?,
                               do:
                                 evidence_breadth_retry_progress_reason(
                                   available_evidence_discipline
                                 ),
                               else:
                                 evidence_breadth_retry_no_progress_reason(
                                   available_evidence_discipline
                                 )
                             ),
                             next_iteration + 1
                           ),
                         tool_calls:
                           consolidation_tool_calls ++
                             [
                               %{
                                 "iteration" => next_iteration + 1,
                                 "phase" => "evidence_breadth_source_retry_recall",
                                 "tool" => "recall",
                                 "query" => source_retry_payload["query"],
                                 "result_count" => length(source_retry_recall["results"]),
                                 "input" => %{
                                   "query" => source_retry_payload["query"],
                                   "payload" =>
                                     Map.take(source_retry_payload, [
                                       "budget",
                                       "source_shortfall_type",
                                       "tags",
                                       "query_timestamp",
                                       "verification_mode",
                                       "source_novel_only"
                                     ])
                                 },
                                 "output" => %{
                                   "result_ids" =>
                                     Enum.map(source_retry_recall["results"], & &1["id"]),
                                   "evidence_progress" => source_retry_progress?,
                                   "evidence_status" => source_retry_evidence_discipline["status"]
                                 }
                               }
                             ]
                       }}
                    end

                  true ->
                    {:ok,
                     %{
                       recall_result: recall_result,
                       grounded_results: consolidated_grounded_results,
                       observations: refreshed_observations,
                       mental_models: refreshed_mental_models,
                       current_plan: replan,
                       plan_events: replan_events,
                       termination:
                         reflect_termination(
                           if(consolidated_progress?,
                             do: evidence_breadth_progress_status(available_evidence_discipline),
                             else:
                               evidence_breadth_no_progress_status(available_evidence_discipline)
                           ),
                           if(consolidated_progress?,
                             do:
                               evidence_breadth_consolidation_progress_reason(
                                 available_evidence_discipline,
                                 "planner-directed source consolidation improved evidence breadth"
                               ),
                             else:
                               evidence_breadth_consolidation_no_progress_reason(
                                 available_evidence_discipline,
                                 "planner-directed source consolidation did not improve evidence breadth"
                               )
                           ),
                           next_iteration
                         ),
                       tool_calls: consolidation_tool_calls
                     }}
                end
              end

            planner_directed_source_consolidation_skip?(
              replan,
              available_evidence_discipline
            ) ->
              {:ok,
               %{
                 recall_result: recall_result,
                 grounded_results: grounded_results,
                 observations: observations,
                 mental_models: mental_models,
                 current_plan: replan,
                 plan_events: replan_events,
                 termination:
                   reflect_termination(
                     "source_provenance_consolidation_unavailable",
                     "planner requested consolidation but raw source provenance breadth requires new sources",
                     termination["iteration"]
                   ),
                 tool_calls:
                   tool_calls ++
                     [
                       %{
                         "iteration" => termination["iteration"],
                         "phase" => "evidence_breadth_source_consolidation_skipped",
                         "tool" => "consolidate",
                         "scope_keys" => reflect_scope_keys(payload),
                         "input" => consolidation_payload(payload),
                         "output" => %{
                           "status" => "skipped",
                           "reason" => "raw_source_provenance_required"
                         }
                       }
                     ]
               }}

            true ->
              {:ok,
               %{
                 recall_result: recall_result,
                 grounded_results: grounded_results,
                 observations: observations,
                 mental_models: mental_models,
                 current_plan: replan,
                 plan_events: replan_events,
                 termination:
                   reflect_termination(
                     replan_stop_status(replan, should_verify?, seen_queries),
                     replan_stop_reason(replan, should_verify?, seen_queries),
                     termination["iteration"]
                   ),
                 tool_calls: tool_calls
               }}
          end
        end
      end
    else
      {:ok,
       %{
         recall_result: recall_result,
         grounded_results: grounded_results,
         observations: observations,
         mental_models: mental_models,
         current_plan: current_plan,
         plan_events: plan_events,
         termination: termination,
         tool_calls: tool_calls
       }}
    end
  end

  defp maybe_replan_after_verification(
         {:ok,
          %{
            recall_result: recall_result,
            grounded_results: grounded_results,
            observations: observations,
            mental_models: mental_models,
            current_plan: current_plan,
            plan_events: plan_events,
            tool_calls: tool_calls
          }},
         ctx,
         payload,
         opts,
         llm,
         bank_profile,
         directives,
         previous_plan: previous_plan,
         seen_queries: seen_queries,
         verification_index: verification_index,
         iteration: iteration,
         remaining_replans: remaining_replans
       ) do
    should_replan? =
      not previous_plan.needs_consolidation and not previous_plan.answer_ready and
        remaining_replans > 0

    if should_replan? do
      replan_prompt =
        Foresight.Prompts.Reflect.Plan.V1.build(
          payload["query"],
          payload,
          bank_profile,
          recall_result["results"],
          observations,
          directives,
          mental_models
        )

      with {:ok, replan} <-
             llm.complete_structured(
               replan_prompt,
               [],
               Foresight.Prompts.ReflectPlanResponse,
               []
             ) do
        replan_events =
          plan_events ++ [%{"phase" => "replan", "prompt" => replan_prompt, "output" => replan}]

        should_verify_again? =
          not replan.needs_consolidation and not replan.answer_ready and
            is_binary(replan.focus_query) and String.trim(replan.focus_query) != "" and
            replan.focus_query not in seen_queries

        if replan.needs_consolidation do
          with {:ok, _} <- consolidate(ctx, consolidation_payload(payload), opts),
               {:ok, refreshed_recall} <-
                 recall(ctx, Map.put(payload, "query", replan.focus_query), opts) do
            {expanded_refreshed_results, refreshed_expand_tool_call} =
              maybe_expand_reflect_results(
                ctx.bank,
                refreshed_recall["results"],
                payload,
                iteration + 1
              )

            refreshed_recall = Map.put(refreshed_recall, "results", expanded_refreshed_results)
            refreshed_observations = reflect_observations(ctx, payload)

            {:ok,
             %{
               recall_result: refreshed_recall,
               grounded_results:
                 merge_grounding_results(
                   refreshed_observations["observations"],
                   refreshed_recall["results"]
                 ),
               observations: refreshed_observations,
               mental_models: active_mental_models(ctx.bank, payload),
               current_plan: replan,
               plan_events: replan_events,
               termination:
                 reflect_termination(
                   "consolidated",
                   replan.reason || "replan requested consolidation",
                   iteration + 2
                 ),
               tool_calls:
                 tool_calls ++
                   [
                     %{
                       "iteration" => iteration,
                       "phase" => "replan_consolidate",
                       "tool" => "consolidate",
                       "scope_keys" => requested_scopes(consolidation_payload(payload)),
                       "input" => consolidation_payload(payload),
                       "output" => %{"status" => "ok"}
                     },
                     %{
                       "iteration" => iteration + 1,
                       "phase" => "replan_final_recall",
                       "tool" => "recall",
                       "query" => replan.focus_query,
                       "result_count" => length(refreshed_recall["results"]),
                       "input" => %{"query" => replan.focus_query},
                       "output" => %{
                         "result_ids" => Enum.map(refreshed_recall["results"], & &1["id"])
                       }
                     }
                   ] ++
                   maybe_list(refreshed_expand_tool_call) ++
                   [
                     %{
                       "iteration" => iteration + 2,
                       "phase" => "replan_final_observations",
                       "tool" => "search_observations",
                       "type" => "observation",
                       "result_count" => length(refreshed_observations["observations"]),
                       "input" => %{
                         "type" => "observation",
                         "tags" => payload["tags"],
                         "scope_keys" => reflect_scope_keys(payload)
                       },
                       "output" => Map.drop(refreshed_observations, ["observations"])
                     }
                   ]
             }}
          end
        else
          if should_verify_again? do
            with {:ok, verification_recall} <-
                   recall(ctx, Map.put(payload, "query", replan.focus_query), opts) do
              {expanded_verification_results, verification_expand_tool_call} =
                maybe_expand_reflect_results(
                  ctx.bank,
                  verification_recall["results"],
                  payload,
                  iteration + 1
                )

              merged_results =
                merge_reflect_recall_results(
                  recall_result["results"],
                  expanded_verification_results
                )

              updated_grounded_results =
                merge_grounding_results(observations["observations"], merged_results)

              verification_progress? =
                verification_results_progress?(
                  grounded_results,
                  updated_grounded_results,
                  recall_result["results"],
                  expanded_verification_results,
                  mental_models,
                  opts
                )

              {:ok,
               %{
                 recall_result: Map.put(recall_result, "results", merged_results),
                 grounded_results: updated_grounded_results,
                 observations: observations,
                 mental_models: mental_models,
                 current_plan: replan,
                 plan_events: replan_events,
                 termination:
                   reflect_termination(
                     if(verification_progress?,
                       do: "verification_progress",
                       else: "verification_no_progress"
                     ),
                     if(
                       verification_progress?,
                       do: replan.reason || "iterative verification recall completed",
                       else: "verification recall did not improve grounding"
                     ),
                     iteration
                   ),
                 tool_calls:
                   tool_calls ++
                     [
                       %{
                         "iteration" => iteration,
                         "phase" => "verification_recall_#{verification_index}",
                         "tool" => "recall",
                         "query" => replan.focus_query,
                         "result_count" => length(expanded_verification_results),
                         "input" => %{"query" => replan.focus_query},
                         "output" => %{
                           "result_ids" => Enum.map(expanded_verification_results, & &1["id"])
                         }
                       }
                     ] ++ maybe_list(verification_expand_tool_call)
               }}
              |> then(fn result ->
                if verification_progress? do
                  maybe_replan_after_verification(
                    result,
                    ctx,
                    payload,
                    opts,
                    llm,
                    bank_profile,
                    directives,
                    previous_plan: replan,
                    seen_queries: seen_queries ++ [replan.focus_query],
                    verification_index: verification_index + 1,
                    iteration: iteration + 1,
                    remaining_replans: remaining_replans - 1
                  )
                else
                  result
                end
              end)
            end
          else
            {:ok,
             %{
               recall_result: recall_result,
               grounded_results: grounded_results,
               observations: observations,
               mental_models: mental_models,
               current_plan: replan,
               plan_events: replan_events,
               termination:
                 reflect_termination(
                   replan_stop_status(replan, should_verify_again?, seen_queries),
                   replan_stop_reason(replan, should_verify_again?, seen_queries),
                   iteration - 1
                 ),
               tool_calls: tool_calls
             }}
          end
        end
      end
    else
      {:ok,
       %{
         recall_result: recall_result,
         grounded_results: grounded_results,
         observations: observations,
         mental_models: mental_models,
         current_plan: current_plan,
         plan_events: plan_events,
         termination:
           reflect_termination(
             "budget_exhausted",
             "reflect iteration budget exhausted",
             iteration - 1
           ),
         tool_calls: tool_calls
       }}
    end
  end

  defp initial_reflect_termination(payload, plan, max_iterations, fallback_reason) do
    cond do
      plan.answer_ready ->
        reflect_termination("planner_satisfied", plan.reason || fallback_reason, 1)

      plan.needs_consolidation ->
        reflect_termination(
          "consolidated",
          plan.reason || fallback_reason,
          min(6, max_iterations)
        )

      max_iterations <= 1 and plan.focus_query != payload["query"] ->
        reflect_termination("budget_exhausted", "verification skipped by iteration budget", 1)

      true ->
        reflect_termination("stopped", plan.reason || fallback_reason, 1)
    end
  end

  defp verification_skip_status(plan, payload, max_iterations) do
    cond do
      plan.answer_ready -> "planner_satisfied"
      max_iterations <= 1 and plan.focus_query != payload["query"] -> "budget_exhausted"
      unusable_focus_query?(plan.focus_query) -> "no_usable_refinement_query"
      duplicate_focus_query?(plan.focus_query, [payload["query"]]) -> "duplicate_query_suppressed"
      true -> "stopped"
    end
  end

  defp verification_skip_reason(plan, payload, max_iterations) do
    cond do
      plan.answer_ready ->
        plan.reason || "planner marked answer ready"

      max_iterations <= 1 and plan.focus_query != payload["query"] ->
        "verification skipped by iteration budget"

      unusable_focus_query?(plan.focus_query) ->
        "planner returned no usable refinement query"

      duplicate_focus_query?(plan.focus_query, [payload["query"]]) ->
        "planner returned a previously used focus query"

      true ->
        plan.reason || "verification not required"
    end
  end

  defp replan_stop_status(replan, should_verify_again?, seen_queries) do
    cond do
      replan.answer_ready -> "planner_satisfied"
      should_verify_again? -> "verification_progress"
      unusable_focus_query?(replan.focus_query) -> "no_usable_refinement_query"
      duplicate_focus_query?(replan.focus_query, seen_queries) -> "duplicate_query_suppressed"
      true -> "stopped"
    end
  end

  defp replan_stop_reason(replan, should_verify_again?, seen_queries) do
    cond do
      replan.answer_ready ->
        replan.reason || "planner marked answer ready after verification"

      should_verify_again? ->
        replan.reason || "continuing verification"

      unusable_focus_query?(replan.focus_query) ->
        "planner returned no usable refinement query"

      duplicate_focus_query?(replan.focus_query, seen_queries) ->
        "planner returned a previously used focus query"

      true ->
        replan.reason || "replan produced no new refinement step"
    end
  end

  defp duplicate_focus_query?(query, seen_queries) when is_binary(query) do
    trimmed = String.trim(query)
    trimmed != "" and trimmed in seen_queries
  end

  defp duplicate_focus_query?(_query, _seen_queries), do: false

  defp verification_results_progress?(
         before_grounded_results,
         after_grounded_results,
         existing_results,
         new_results,
         mental_models,
         opts
       ) do
    before_discipline =
      available_reflect_evidence_discipline(before_grounded_results, mental_models, opts)

    if evidence_discipline_replan?(before_discipline) do
      after_discipline =
        available_reflect_evidence_discipline(after_grounded_results, mental_models, opts)

      evidence_discipline_progress?(before_discipline, after_discipline)
    else
      length(merge_reflect_recall_results(existing_results, new_results)) >
        length(existing_results)
    end
  end

  defp reflect_seen_queries(tool_calls, initial_query) do
    ([initial_query] ++ Enum.map(tool_calls, &Map.get(&1, "query")))
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp evidence_discipline_replan?(%{"status" => status})
       when status in [
              "blocked_thin_grounding",
              "blocked_low_support_diversity",
              "blocked_low_provenance_diversity",
              "blocked_low_source_provenance",
              "blocked_low_source_family_diversity",
              "blocked_low_source_lineage_diversity",
              "blocked_low_evidence_family_diversity"
            ],
       do: true

  defp evidence_discipline_replan?(_discipline), do: false

  defp evidence_discipline_progress?(before_discipline, after_discipline) do
    case targeted_evidence_discipline_progress?(before_discipline, after_discipline) do
      {:known, result} ->
        result

      :unknown ->
        after_discipline["status"] == "ok" or
          evidence_discipline_progress_score(after_discipline) >
            evidence_discipline_progress_score(before_discipline)
    end
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_thin_grounding"} = before_discipline,
         after_discipline
       ) do
    {:known,
     evidence_metric(after_discipline, "used_grounding_count") >
       evidence_metric(before_discipline, "used_grounding_count")}
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_low_support_diversity"} = before_discipline,
         after_discipline
       ) do
    {:known,
     evidence_metric(after_discipline, "used_grounding_diversity_count") >
       evidence_metric(before_discipline, "used_grounding_diversity_count")}
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_low_provenance_diversity"} = before_discipline,
         after_discipline
       ) do
    {:known,
     evidence_metric(after_discipline, "used_provenance_cluster_count") >
       evidence_metric(before_discipline, "used_provenance_cluster_count")}
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_low_source_provenance"} = before_discipline,
         after_discipline
       ) do
    {:known,
     evidence_metric(after_discipline, "used_source_provenance_cluster_count") >
       evidence_metric(before_discipline, "used_source_provenance_cluster_count")}
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_low_source_family_diversity"} = before_discipline,
         after_discipline
       ) do
    {:known,
     evidence_metric(after_discipline, "used_source_family_count") >
       evidence_metric(before_discipline, "used_source_family_count")}
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_low_source_lineage_diversity"} = before_discipline,
         after_discipline
       ) do
    {:known,
     evidence_metric(after_discipline, "used_source_lineage_count") >
       evidence_metric(before_discipline, "used_source_lineage_count")}
  end

  defp targeted_evidence_discipline_progress?(
         %{"status" => "blocked_low_evidence_family_diversity"} = before_discipline,
         after_discipline
       ) do
    {:known, evidence_family_progress?(before_discipline, after_discipline)}
  end

  defp targeted_evidence_discipline_progress?(_before_discipline, _after_discipline), do: :unknown

  defp evidence_discipline_progress_score(discipline) when is_map(discipline) do
    [
      "used_grounding_count",
      "used_grounding_diversity_count",
      "used_provenance_cluster_count",
      "used_source_provenance_cluster_count",
      "used_source_family_count",
      "used_source_lineage_count",
      "used_evidence_family_count"
    ]
    |> Enum.map(&(Map.get(discipline, &1, 0) || 0))
    |> Enum.sum()
  end

  defp evidence_discipline_progress_score(_discipline), do: 0

  defp evidence_metric(discipline, key) when is_map(discipline) do
    Map.get(discipline, key, 0) || 0
  end

  defp evidence_metric(_discipline, _key), do: 0

  defp evidence_family_progress?(before_discipline, after_discipline) do
    cond do
      raw_memory_breadth_shortfall?(before_discipline) ->
        evidence_metric(after_discipline, "used_memory_evidence_family_count") >
          evidence_metric(before_discipline, "used_memory_evidence_family_count")

      true ->
        evidence_metric(after_discipline, "used_primary_evidence_family_count") >
          evidence_metric(before_discipline, "used_primary_evidence_family_count")
    end
  end

  defp evidence_breadth_consolidation_retry?(
         %{"status" => "blocked_low_evidence_family_diversity"},
         payload,
         next_iteration,
         max_iterations
       ) do
    reflect_scope_keys(payload) != [] and next_iteration < max_iterations
  end

  defp evidence_breadth_consolidation_retry?(
         _discipline,
         _payload,
         _next_iteration,
         _max_iterations
       ),
       do: false

  defp evidence_breadth_source_retry?(
         %{"status" => status},
         _payload,
         next_iteration,
         max_iterations
       )
       when status in [
              "blocked_low_source_provenance",
              "blocked_low_source_family_diversity",
              "blocked_low_source_lineage_diversity"
            ] do
    next_iteration < max_iterations
  end

  defp evidence_breadth_source_retry?(_discipline, _payload, _next_iteration, _max_iterations),
    do: false

  defp evidence_breadth_memory_retry?(
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         %{"verification_mode" => "memory_breadth"},
         next_iteration,
         max_iterations
       ) do
    raw_memory_breadth_shortfall?(discipline) and next_iteration < max_iterations
  end

  defp evidence_breadth_memory_retry?(_discipline, _payload, _next_iteration, _max_iterations),
    do: false

  defp evidence_breadth_memory_source_retry?(
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         next_iteration,
         max_iterations
       ) do
    raw_memory_breadth_shortfall?(discipline) and next_iteration < max_iterations
  end

  defp evidence_breadth_memory_source_retry?(_discipline, _next_iteration, _max_iterations),
    do: false

  defp evidence_breadth_source_consolidation_retry?(
         %{"status" => status},
         payload,
         next_iteration,
         max_iterations
       )
       when status in [
              "blocked_low_source_family_diversity",
              "blocked_low_source_lineage_diversity"
            ] do
    reflect_scope_keys(payload) != [] and next_iteration < max_iterations
  end

  defp evidence_breadth_source_consolidation_retry?(
         _discipline,
         _payload,
         _next_iteration,
         _max_iterations
       ),
       do: false

  defp evidence_breadth_source_consolidation_skip?(%{
         "status" => "blocked_low_source_provenance"
       }),
       do: true

  defp evidence_breadth_source_consolidation_skip?(_discipline), do: false

  defp broaden_memory_breadth_payload(payload, query) do
    payload
    |> Map.delete("source_linked_only")
    |> Map.put("query", String.trim(query) <> " broaden raw memory breadth")
    |> Map.put("budget", "high")
    |> Map.put("verification_mode", "memory_breadth")
    |> Map.put("types", ["experience", "world"])
  end

  defp broaden_memory_source_payload(payload, query) do
    payload
    |> Map.put("query", String.trim(query) <> " broaden raw memory breadth via sources")
    |> memory_source_verification_payload()
  end

  defp memory_source_verification_payload(payload, query) do
    payload
    |> Map.put("query", query)
    |> memory_source_verification_payload()
  end

  defp memory_source_verification_payload(payload) do
    payload
    |> Map.put("budget", "high")
    |> Map.put("verification_mode", "source_expansion")
    |> Map.put("source_linked_only", true)
    |> Map.put("source_shortfall_type", "raw_memory_breadth")
    |> Map.put("types", ["experience", "world"])
  end

  defp broaden_source_expansion_payload(payload, query, discipline) do
    shortfall_type = source_retry_shortfall_type(discipline)

    broadened_query =
      build_source_retry_query(query, shortfall_type)

    payload
    |> Map.put("query", broadened_query)
    |> Map.put("budget", "high")
    |> Map.put("verification_mode", "source_expansion")
    |> Map.put("source_shortfall_type", shortfall_type)
  end

  defp source_retry_shortfall_type(%{"status" => "blocked_low_source_provenance"}),
    do: "source_provenance"

  defp source_retry_shortfall_type(%{"status" => "blocked_low_source_family_diversity"}),
    do: "source_family"

  defp source_retry_shortfall_type(%{"status" => "blocked_low_source_lineage_diversity"}),
    do: "source_lineage"

  defp source_retry_shortfall_type(_discipline), do: "source_breadth"

  defp build_source_retry_query(query, shortfall_type) do
    prefix =
      case String.trim(to_string(query)) do
        "" -> "broaden source breadth"
        trimmed -> trimmed
      end

    suffix =
      case shortfall_type do
        "source_provenance" -> "broaden source provenance"
        "source_lineage" -> "broaden source lineage"
        "source_family" -> "broaden source family"
        _ -> "broaden source breadth"
      end

    prefix <> " " <> suffix
  end

  defp evidence_breadth_no_progress_status(%{"status" => "blocked_low_source_provenance"}),
    do: "source_provenance_no_progress"

  defp evidence_breadth_no_progress_status(%{"status" => "blocked_low_source_family_diversity"}),
    do: "source_family_breadth_no_progress"

  defp evidence_breadth_no_progress_status(%{"status" => "blocked_low_source_lineage_diversity"}),
    do: "source_lineage_breadth_no_progress"

  defp evidence_breadth_no_progress_status(%{"status" => "blocked_low_provenance_diversity"}),
    do: "provenance_breadth_no_progress"

  defp evidence_breadth_no_progress_status(%{"status" => "blocked_low_support_diversity"}),
    do: "support_diversity_no_progress"

  defp evidence_breadth_no_progress_status(%{"status" => "blocked_thin_grounding"}),
    do: "thin_grounding_no_progress"

  defp evidence_breadth_no_progress_status(
         %{"status" => "blocked_low_evidence_family_diversity"} = d
       ) do
    if raw_memory_breadth_shortfall?(d) do
      "raw_memory_breadth_no_progress"
    else
      "evidence_family_breadth_no_progress"
    end
  end

  defp evidence_breadth_no_progress_status(_discipline), do: "evidence_breadth_no_progress"

  defp evidence_breadth_progress_status(%{"status" => "blocked_low_source_provenance"}),
    do: "source_provenance_progress"

  defp evidence_breadth_progress_status(%{"status" => "blocked_low_source_family_diversity"}),
    do: "source_family_breadth_progress"

  defp evidence_breadth_progress_status(%{"status" => "blocked_low_source_lineage_diversity"}),
    do: "source_lineage_breadth_progress"

  defp evidence_breadth_progress_status(
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline
       ) do
    if raw_memory_breadth_shortfall?(discipline),
      do: "raw_memory_breadth_progress",
      else: "evidence_breadth_progress"
  end

  defp evidence_breadth_progress_status(_discipline), do: "evidence_breadth_progress"

  defp evidence_breadth_progress_reason(
         %{"status" => "blocked_low_source_provenance"},
         _fallback_reason
       ),
       do: "verification recall improved raw source provenance breadth"

  defp evidence_breadth_progress_reason(
         %{"status" => "blocked_low_source_family_diversity"},
         _fallback_reason
       ),
       do: "verification recall improved source family breadth"

  defp evidence_breadth_progress_reason(
         %{"status" => "blocked_low_source_lineage_diversity"},
         _fallback_reason
       ),
       do: "verification recall improved source lineage breadth"

  defp evidence_breadth_progress_reason(
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         fallback_reason
       ) do
    if raw_memory_breadth_shortfall?(discipline),
      do: "verification recall improved raw-memory breadth",
      else: fallback_reason || "verification recall added evidence breadth"
  end

  defp evidence_breadth_progress_reason(_discipline, fallback_reason),
    do: fallback_reason || "verification recall added evidence breadth"

  defp evidence_breadth_retry_progress_reason(%{"status" => "blocked_low_source_provenance"}),
    do: "source-expansion retry improved raw source provenance breadth"

  defp evidence_breadth_retry_progress_reason(%{
         "status" => "blocked_low_source_family_diversity"
       }),
       do: "source-expansion retry improved source family breadth"

  defp evidence_breadth_retry_progress_reason(%{
         "status" => "blocked_low_source_lineage_diversity"
       }),
       do: "source-expansion retry improved source lineage breadth"

  defp evidence_breadth_retry_progress_reason(_discipline),
    do: "source-expansion retry improved evidence breadth"

  defp evidence_breadth_retry_no_progress_reason(%{
         "status" => "blocked_low_source_provenance"
       }),
       do: "source-expansion retry did not improve raw source provenance breadth"

  defp evidence_breadth_retry_no_progress_reason(%{
         "status" => "blocked_low_source_family_diversity"
       }),
       do: "source-expansion retry did not improve source family breadth"

  defp evidence_breadth_retry_no_progress_reason(%{
         "status" => "blocked_low_source_lineage_diversity"
       }),
       do: "source-expansion retry did not improve source lineage breadth"

  defp evidence_breadth_retry_no_progress_reason(_discipline),
    do: "source-expansion retry did not improve evidence breadth"

  defp evidence_breadth_consolidation_progress_reason(
         %{"status" => "blocked_low_source_family_diversity"},
         _fallback_reason
       ),
       do: "source consolidation improved source family breadth"

  defp evidence_breadth_consolidation_progress_reason(
         %{"status" => "blocked_low_source_lineage_diversity"},
         _fallback_reason
       ),
       do: "source consolidation improved source lineage breadth"

  defp evidence_breadth_consolidation_progress_reason(
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         fallback_reason
       ) do
    if raw_memory_breadth_shortfall?(discipline),
      do: "consolidation improved raw-memory breadth",
      else: fallback_reason
  end

  defp evidence_breadth_consolidation_progress_reason(_discipline, fallback_reason),
    do: fallback_reason

  defp evidence_breadth_consolidation_no_progress_reason(
         %{"status" => "blocked_low_source_family_diversity"},
         _fallback_reason
       ),
       do: "source consolidation did not improve source family breadth"

  defp evidence_breadth_consolidation_no_progress_reason(
         %{"status" => "blocked_low_source_lineage_diversity"},
         _fallback_reason
       ),
       do: "source consolidation did not improve source lineage breadth"

  defp evidence_breadth_consolidation_no_progress_reason(
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         fallback_reason
       ) do
    if raw_memory_breadth_shortfall?(discipline),
      do: "consolidation did not improve raw-memory breadth",
      else: fallback_reason
  end

  defp evidence_breadth_consolidation_no_progress_reason(_discipline, fallback_reason),
    do: fallback_reason

  defp evidence_breadth_no_progress_reason(%{"status" => "blocked_low_source_provenance"}) do
    "verification recall did not improve source provenance breadth"
  end

  defp evidence_breadth_no_progress_reason(%{"status" => "blocked_low_source_family_diversity"}) do
    "verification recall did not improve source family breadth"
  end

  defp evidence_breadth_no_progress_reason(%{"status" => "blocked_low_source_lineage_diversity"}) do
    "verification recall did not improve source lineage breadth"
  end

  defp evidence_breadth_no_progress_reason(%{"status" => "blocked_low_provenance_diversity"}) do
    "verification recall did not improve provenance breadth"
  end

  defp evidence_breadth_no_progress_reason(%{"status" => "blocked_low_support_diversity"}) do
    "verification recall did not improve support diversity"
  end

  defp evidence_breadth_no_progress_reason(%{"status" => "blocked_thin_grounding"}) do
    "verification recall did not improve grounded support count"
  end

  defp evidence_breadth_no_progress_reason(
         %{"status" => "blocked_low_evidence_family_diversity"} = d
       ) do
    if raw_memory_breadth_shortfall?(d) do
      "verification recall did not improve raw-memory breadth"
    else
      "verification recall did not improve evidence breadth"
    end
  end

  defp evidence_breadth_no_progress_reason(_discipline) do
    "verification recall did not improve evidence breadth"
  end

  defp reflect_evidence_shortfall_prompt(%{} = discipline) do
    shortfall_class = evidence_family_shortfall_class(discipline)

    discipline
    |> Map.take([
      "status",
      "reason",
      "min_source_family_count",
      "used_source_family_count",
      "min_source_lineage_count",
      "used_source_lineage_count",
      "min_evidence_family_count",
      "used_evidence_family_count",
      "used_memory_evidence_family_count",
      "used_observation_evidence_family_count",
      "used_primary_evidence_family_count",
      "used_derived_evidence_family_count"
    ])
    |> Map.put(
      "evidence_family_shortfall_class",
      shortfall_class
    )
    |> maybe_put_targeted_breadth_metric(shortfall_class)
  end

  defp reflect_evidence_shortfall_prompt(_discipline), do: %{}

  defp maybe_put_targeted_breadth_metric(prompt, "raw_memory_breadth"),
    do: Map.put(prompt, "targeted_breadth_metric", "used_memory_evidence_family_count")

  defp maybe_put_targeted_breadth_metric(prompt, _shortfall_class), do: prompt

  defp evidence_family_shortfall_class(%{"status" => "blocked_low_evidence_family_diversity"} = d) do
    cond do
      evidence_metric(d, "used_derived_evidence_family_count") > 0 and
          evidence_metric(d, "used_primary_evidence_family_count") <
            evidence_metric(d, "min_evidence_family_count") ->
        "derived_only_breadth"

      raw_memory_breadth_shortfall?(d) ->
        "raw_memory_breadth"

      true ->
        "generic"
    end
  end

  defp evidence_family_shortfall_class(_discipline), do: nil

  defp raw_memory_breadth_shortfall?(discipline) do
    evidence_metric(discipline, "used_memory_evidence_family_count") <
      evidence_metric(discipline, "min_evidence_family_count")
  end

  defp reflect_evidence_verification_payload(payload, query, %{"status" => status})
       when status in [
              "blocked_low_provenance_diversity",
              "blocked_low_source_provenance",
              "blocked_low_source_family_diversity",
              "blocked_low_source_lineage_diversity"
            ] do
    payload
    |> Map.put("query", query)
    |> Map.put("budget", "high")
    |> Map.put("verification_mode", "source_expansion")
  end

  defp reflect_evidence_verification_payload(
         payload,
         query,
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline
       ) do
    case evidence_family_shortfall_class(discipline) do
      "raw_memory_breadth" ->
        payload
        |> Map.put("query", query)
        |> Map.put("budget", "high")
        |> Map.put("verification_mode", "memory_breadth")
        |> Map.put("types", ["experience", "world"])

      _ ->
        Map.put(payload, "query", query)
    end
  end

  defp reflect_evidence_verification_payload(payload, query, _discipline) do
    Map.put(payload, "query", query)
  end

  defp reflect_evidence_verification_payload(
         payload,
         query,
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         "memory_source_breadth"
       ) do
    case evidence_family_shortfall_class(discipline) do
      "raw_memory_breadth" -> memory_source_verification_payload(payload, query)
      _ -> reflect_evidence_verification_payload(payload, query, discipline)
    end
  end

  defp reflect_evidence_verification_payload(
         payload,
         query,
         %{"status" => "blocked_low_evidence_family_diversity"} = discipline,
         "memory_source_then_memory_breadth"
       ) do
    case evidence_family_shortfall_class(discipline) do
      "raw_memory_breadth" -> memory_source_verification_payload(payload, query)
      _ -> reflect_evidence_verification_payload(payload, query, discipline)
    end
  end

  defp reflect_evidence_verification_payload(
         payload,
         query,
         discipline,
         refinement_intent
       )
       when refinement_intent in [
              "source_family_breadth",
              "source_lineage_breadth",
              "source_provenance_breadth"
            ] do
    case planner_source_shortfall_type(refinement_intent) do
      nil ->
        reflect_evidence_verification_payload(payload, query, discipline)

      shortfall_type ->
        planner_directed_source_verification_payload(payload, query, shortfall_type)
    end
  end

  defp reflect_evidence_verification_payload(payload, query, discipline, _refinement_intent) do
    reflect_evidence_verification_payload(payload, query, discipline)
  end

  defp planner_directed_source_verification_payload(payload, query, shortfall_type) do
    payload
    |> Map.put("query", query)
    |> Map.put("budget", "high")
    |> Map.put("verification_mode", "source_expansion")
    |> Map.put("source_shortfall_type", shortfall_type)
    |> maybe_put_source_novel_only(shortfall_type)
  end

  defp maybe_put_source_novel_only(payload, "source_provenance"),
    do: Map.put(payload, "source_novel_only", true)

  defp maybe_put_source_novel_only(payload, _shortfall_type), do: payload

  defp planner_source_shortfall_type("source_family_breadth"), do: "source_family"
  defp planner_source_shortfall_type("source_lineage_breadth"), do: "source_lineage"
  defp planner_source_shortfall_type("source_provenance_breadth"), do: "source_provenance"
  defp planner_source_shortfall_type(_intent), do: nil

  defp direct_memory_source_refinement?(
         %{refinement_intent: refinement_intent},
         %{
           "verification_mode" => "source_expansion",
           "source_shortfall_type" => "raw_memory_breadth"
         }
       )
       when refinement_intent in ["memory_source_breadth", "memory_source_then_memory_breadth"],
       do: true

  defp direct_memory_source_refinement?(_plan, _payload), do: false

  defp planner_directed_source_consolidation?(
         %{needs_consolidation: true, refinement_intent: refinement_intent},
         evidence_discipline,
         payload,
         iteration,
         max_iterations
       )
       when refinement_intent in ["source_family_breadth", "source_lineage_breadth"] do
    evidence_breadth_source_consolidation_retry?(
      evidence_discipline,
      payload,
      iteration - 1,
      max_iterations
    )
  end

  defp planner_directed_source_consolidation?(
         _plan,
         _evidence_discipline,
         _payload,
         _iteration,
         _max_iterations
       ),
       do: false

  defp planner_directed_source_consolidation_skip?(
         %{needs_consolidation: true, refinement_intent: "source_provenance_breadth"},
         %{"status" => "blocked_low_source_provenance"}
       ),
       do: true

  defp planner_directed_source_consolidation_skip?(_plan, _evidence_discipline), do: false

  defp source_consolidation_requires_retry?(%{"status" => status})
       when status in [
              "blocked_low_source_family_diversity",
              "blocked_low_source_lineage_diversity"
            ],
       do: true

  defp source_consolidation_requires_retry?(_evidence_discipline), do: false

  defp planner_directed_memory_retry_after_source?(
         %{refinement_intent: "memory_source_then_memory_breadth"},
         %{
           "verification_mode" => "source_expansion",
           "source_shortfall_type" => "raw_memory_breadth"
         },
         next_iteration,
         max_iterations
       ),
       do: next_iteration < max_iterations

  defp planner_directed_memory_retry_after_source?(
         _plan,
         _payload,
         _next_iteration,
         _max_iterations
       ),
       do: false

  defp unusable_focus_query?(query) when is_binary(query), do: String.trim(query) == ""
  defp unusable_focus_query?(_query), do: true

  defp reflect_termination(status, reason, iteration) do
    %{
      "status" => status,
      "reason" => reason,
      "iteration" => iteration
    }
  end

  defp reflect_branch_summary(tool_calls, termination, plan_events, max_iterations) do
    phases = Enum.map(tool_calls, &Map.get(&1, "phase"))
    source_first? = direct_source_first_tool_call?(tool_calls)
    planner_plan = reflect_branch_planner_plan(plan_events)
    source_provenance_novel_only? = source_provenance_novel_only_tool_call?(tool_calls)
    source_breadth_verification? = source_breadth_verification_tool_call?(tool_calls)

    branch_type =
      reflect_branch_type(
        phases,
        planner_plan,
        termination,
        source_first?,
        source_provenance_novel_only?,
        source_breadth_verification?
      )

    provenance_guard_origin = source_provenance_guard_origin(phases, planner_plan, branch_type)
    source_progression = reflect_source_progression(phases, branch_type)
    source_outcome = reflect_source_outcome(branch_type, source_progression, termination)
    memory_outcome = reflect_memory_outcome(branch_type, termination)
    verification_progression = reflect_verification_progression(phases, branch_type, termination)

    verification_outcome =
      reflect_verification_outcome(branch_type, verification_progression, termination)

    budget_override =
      reflect_budget_override(tool_calls, max_iterations, branch_type, verification_progression)

    %{
      "type" => branch_type,
      "source_progression" => source_progression,
      "source_outcome" => source_outcome,
      "memory_outcome" => memory_outcome,
      "verification_progression" => verification_progression,
      "verification_outcome" => verification_outcome,
      "used_source_first" => source_first?,
      "used_source_retry" => "evidence_breadth_source_retry_recall" in phases,
      "used_source_novel_only" => source_provenance_novel_only?,
      "used_memory_retry" => "evidence_breadth_memory_retry_recall" in phases,
      "used_memory_source_retry" => "evidence_breadth_memory_source_retry_recall" in phases,
      "used_consolidation" => used_consolidation_tool_call?(tool_calls),
      "planner_refinement_intent" => planner_plan["refinement_intent"],
      "planner_focus_query" => planner_plan["focus_query"],
      "planner_reason" => planner_plan["reason"],
      "planner_answer_ready" => planner_plan["answer_ready"],
      "planner_needs_consolidation" => planner_plan["needs_consolidation"],
      "planner_intent_matched_branch" =>
        planner_intent_matched_branch?(planner_plan["refinement_intent"], branch_type),
      "source_provenance_guard_origin" => provenance_guard_origin,
      "budget_override" => budget_override,
      "termination_status" => Map.get(termination, "status")
    }
  end

  defp reflect_overview_summary(reflect_branch, termination, plan_events, max_iterations) do
    planner_transitions = reflect_planner_transitions(plan_events)
    initial_plan = List.first(planner_transitions) || %{}
    final_plan = List.last(planner_transitions) || %{}
    initial_expected_branch_type = expected_branch_type_from_plan(initial_plan)
    planner_change_kind = planner_change_kind(initial_plan, final_plan)
    runtime_branch_changed = initial_expected_branch_type != reflect_branch["type"]
    guard_digest = reflect_guard_digest(reflect_branch)

    budget_override =
      reflect_branch["budget_override"] ||
        reflect_budget_override(
          [],
          max_iterations,
          reflect_branch["type"],
          reflect_branch["verification_progression"]
        )

    %{
      "initial_planner_refinement_intent" => initial_plan["refinement_intent"],
      "initial_planner_focus_query" => initial_plan["focus_query"],
      "initial_expected_branch_type" => initial_expected_branch_type,
      "planner_refinement_intent" => reflect_branch["planner_refinement_intent"],
      "planner_focus_query" => reflect_branch["planner_focus_query"],
      "planner_transition_count" => max(length(planner_transitions) - 1, 0),
      "planner_replanned" => length(planner_transitions) > 1,
      "final_branch_from_replan" => length(planner_transitions) > 1,
      "final_branch_origin" =>
        if(length(planner_transitions) > 1, do: "replan", else: "initial_plan"),
      "planner_intent_changed" =>
        initial_plan["refinement_intent"] != final_plan["refinement_intent"],
      "planner_focus_changed" => initial_plan["focus_query"] != final_plan["focus_query"],
      "planner_change_kind" => planner_change_kind,
      "runtime_branch_changed" => runtime_branch_changed,
      "runtime_branch_change_kind" =>
        if(runtime_branch_changed,
          do: "branch_change",
          else: "none"
        ),
      "runtime_branch_change_cause" =>
        runtime_branch_change_cause(runtime_branch_changed, planner_change_kind),
      "branch_type" => reflect_branch["type"],
      "source_progression" => reflect_branch["source_progression"],
      "source_outcome" => reflect_branch["source_outcome"],
      "memory_outcome" => reflect_branch["memory_outcome"],
      "verification_progression" => reflect_branch["verification_progression"],
      "verification_outcome" => reflect_branch["verification_outcome"],
      "planner_intent_matched_branch" => reflect_branch["planner_intent_matched_branch"],
      "guard_type" => guard_digest["type"],
      "guard_origin" => guard_digest["origin"],
      "guard_active" => guard_digest["active"],
      "source_provenance_guard_origin" => reflect_branch["source_provenance_guard_origin"],
      "used_source_first" => reflect_branch["used_source_first"],
      "used_source_retry" => reflect_branch["used_source_retry"],
      "used_memory_retry" => reflect_branch["used_memory_retry"],
      "used_memory_source_retry" => reflect_branch["used_memory_source_retry"],
      "used_consolidation" => reflect_branch["used_consolidation"],
      "used_source_novel_only" => reflect_branch["used_source_novel_only"],
      "budget_override" => budget_override,
      "termination_status" => Map.get(termination, "status")
    }
  end

  defp reflect_budget_override(tool_calls, max_iterations, branch_type, verification_progression) do
    max_iteration_seen =
      tool_calls
      |> Enum.map(&Map.get(&1, "iteration"))
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    active = max_iteration_seen > max_iterations

    %{
      "active" => active,
      "max_iteration_seen" => max_iteration_seen,
      "overrun_by" => max(max_iteration_seen - max_iterations, 0),
      "cause" => reflect_budget_override_cause(active, branch_type, verification_progression)
    }
  end

  defp reflect_budget_override_cause(false, _branch_type, _verification_progression), do: "none"

  defp reflect_budget_override_cause(true, "consolidation", "initial_consolidation"),
    do: "initial_consolidation"

  defp reflect_budget_override_cause(true, "verification_recall", "single_verification"),
    do: "initial_verification"

  defp reflect_budget_override_cause(true, _branch_type, _verification_progression), do: "other"

  defp used_consolidation_tool_call?(tool_calls) do
    Enum.any?(tool_calls, fn tool_call ->
      Map.get(tool_call, "phase") in [
        "auto_consolidate",
        "replan_consolidate",
        "evidence_breadth_consolidate",
        "evidence_breadth_source_consolidate"
      ] and Map.get(tool_call, "skipped") != true
    end)
  end

  defp reflect_guard_digest(%{
         "type" => "source_provenance_guard",
         "source_provenance_guard_origin" => origin
       }) do
    %{"active" => true, "type" => "source_provenance", "origin" => origin}
  end

  defp reflect_guard_digest(_reflect_branch) do
    %{"active" => false, "type" => nil, "origin" => nil}
  end

  defp reflect_verification_progression(phases, branch_type, termination)
       when branch_type in ["verification_recall", "consolidation"] do
    cond do
      "forced_final_recall" in phases ->
        "initial_consolidation"

      "replan_consolidate" in phases ->
        "verification_then_consolidation"

      Enum.any?(phases, &String.starts_with?(&1, "verification_recall_")) ->
        "iterative_verification"

      "verification_recall" in phases or "evidence_breadth_verification_recall" in phases ->
        "single_verification"

      Map.get(termination, "status") in [
        "budget_exhausted",
        "duplicate_query_suppressed",
        "no_usable_refinement_query"
      ] ->
        "verification_skipped"

      true ->
        "none"
    end
  end

  defp reflect_verification_progression(_phases, _branch_type, _termination), do: "none"

  defp reflect_source_outcome(branch_type, _source_progression, termination)
       when branch_type in [
              "source_breadth_verification",
              "source_breadth_retry",
              "source_breadth_consolidation",
              "source_provenance_verification",
              "source_provenance_retry",
              "source_provenance_guard"
            ] do
    Map.get(termination, "status", "in_progress")
  end

  defp reflect_source_outcome(_branch_type, _source_progression, _termination), do: "none"

  defp reflect_memory_outcome(branch_type, termination)
       when branch_type in [
              "direct_source_first",
              "source_first_then_memory_retry",
              "memory_retry_with_source_fallback"
            ] do
    Map.get(termination, "status", "in_progress")
  end

  defp reflect_memory_outcome(_branch_type, _termination), do: "none"

  defp reflect_verification_outcome(branch_type, _verification_progression, termination)
       when branch_type in ["verification_recall", "consolidation"] do
    Map.get(termination, "status", "in_progress")
  end

  defp reflect_verification_outcome(_branch_type, _verification_progression, _termination),
    do: "none"

  defp reflect_source_progression(phases, branch_type) do
    cond do
      "evidence_breadth_source_retry_recall" in phases and
          "evidence_breadth_source_consolidate" in phases ->
        "retry_after_consolidation"

      "evidence_breadth_source_retry_recall" in phases ->
        "retry_after_verification"

      "evidence_breadth_source_consolidate" in phases ->
        "direct_consolidation"

      branch_type in ["source_breadth_verification", "source_provenance_verification"] ->
        "direct_verification"

      true ->
        "none"
    end
  end

  defp reflect_branch_type(
         phases,
         planner_plan,
         termination,
         source_first?,
         source_provenance_novel_only?,
         source_breadth_verification?
       ) do
    cond do
      "evidence_breadth_memory_source_retry_recall" in phases ->
        "memory_retry_with_source_fallback"

      "evidence_breadth_memory_retry_recall" in phases and source_first? ->
        "source_first_then_memory_retry"

      source_first? ->
        "direct_source_first"

      "evidence_breadth_source_consolidation_skipped" in phases ->
        "source_provenance_guard"

      "evidence_breadth_source_retry_recall" in phases and source_provenance_novel_only? ->
        "source_provenance_retry"

      "evidence_breadth_source_consolidate" in phases ->
        "source_breadth_consolidation"

      "replan_consolidate" in phases ->
        "consolidation"

      "forced_final_recall" in phases ->
        "consolidation"

      "evidence_breadth_source_retry_recall" in phases ->
        "source_breadth_retry"

      "evidence_breadth_verification_recall" in phases and source_provenance_novel_only? ->
        "source_provenance_verification"

      "evidence_breadth_verification_recall" in phases and source_breadth_verification? ->
        "source_breadth_verification"

      "evidence_breadth_verification_recall" in phases ->
        "verification_recall"

      generic_verification_phase?(phases) ->
        "verification_recall"

      expected_branch_type_from_plan(planner_plan) == "verification_recall" and
          Map.get(termination, "status") in [
            "budget_exhausted",
            "duplicate_query_suppressed",
            "no_usable_refinement_query"
          ] ->
        "verification_recall"

      true ->
        "default"
    end
  end

  defp generic_verification_phase?(phases) when is_list(phases) do
    Enum.any?(phases, &String.starts_with?(&1, "verification_recall"))
  end

  defp direct_source_first_tool_call?(tool_calls) do
    Enum.any?(tool_calls, fn tool_call ->
      tool_call["phase"] == "evidence_breadth_verification_recall" and
        get_in(tool_call, ["input", "payload", "verification_mode"]) == "source_expansion" and
        get_in(tool_call, ["input", "payload", "source_shortfall_type"]) == "raw_memory_breadth"
    end)
  end

  defp source_provenance_novel_only_tool_call?(tool_calls) do
    Enum.any?(tool_calls, fn tool_call ->
      tool_call["phase"] in [
        "evidence_breadth_verification_recall",
        "evidence_breadth_source_retry_recall"
      ] and
        get_in(tool_call, ["input", "payload", "verification_mode"]) == "source_expansion" and
        get_in(tool_call, ["input", "payload", "source_shortfall_type"]) ==
          "source_provenance" and
        get_in(tool_call, ["input", "payload", "source_novel_only"]) == true
    end)
  end

  defp source_breadth_verification_tool_call?(tool_calls) do
    Enum.any?(tool_calls, fn tool_call ->
      tool_call["phase"] == "evidence_breadth_verification_recall" and
        get_in(tool_call, ["input", "payload", "verification_mode"]) == "source_expansion" and
        get_in(tool_call, ["input", "payload", "source_shortfall_type"]) in [
          "source_family",
          "source_lineage"
        ]
    end)
  end

  defp source_provenance_guard_origin(_phases, _planner_plan, branch_type)
       when branch_type != "source_provenance_guard",
       do: nil

  defp source_provenance_guard_origin(phases, planner_plan, "source_provenance_guard") do
    cond do
      planner_plan["refinement_intent"] == "source_provenance_breadth" and
        planner_plan["needs_consolidation"] == true and
          "evidence_breadth_source_retry_recall" not in phases ->
        "planner_directed"

      "evidence_breadth_source_retry_recall" in phases ->
        "runtime_retry_guard"

      true ->
        "runtime_guard"
    end
  end

  defp reflect_branch_planner_plan(plan_events) do
    plan_events
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn event ->
      case Map.get(event, "output") do
        nil -> nil
        output -> normalize_reflect_plan_output(output)
      end
    end)
  end

  defp reflect_planner_transitions(plan_events) do
    Enum.reduce(plan_events, [], fn event, acc ->
      case Map.get(event, "output") do
        nil -> acc
        output -> acc ++ [normalize_reflect_plan_output(output)]
      end
    end)
  end

  defp planner_change_kind(initial_plan, final_plan) do
    initial_intent = initial_plan["refinement_intent"]
    final_intent = final_plan["refinement_intent"]
    initial_focus = initial_plan["focus_query"]
    final_focus = final_plan["focus_query"]

    cond do
      initial_intent != final_intent -> "strategy_change"
      initial_focus != final_focus -> "focus_only"
      true -> "none"
    end
  end

  defp expected_branch_type_from_plan(plan) do
    cond do
      plan["needs_consolidation"] and
          plan["refinement_intent"] in ["source_family_breadth", "source_lineage_breadth"] ->
        "source_breadth_consolidation"

      plan["needs_consolidation"] and plan["refinement_intent"] == "source_provenance_breadth" ->
        "source_provenance_guard"

      plan["needs_consolidation"] ->
        "consolidation"

      plan["answer_ready"] ->
        "default"

      plan["refinement_intent"] == "memory_source_breadth" ->
        "direct_source_first"

      plan["refinement_intent"] == "memory_source_then_memory_breadth" ->
        "source_first_then_memory_retry"

      plan["refinement_intent"] == "source_provenance_breadth" ->
        "source_provenance_verification"

      plan["refinement_intent"] in ["source_family_breadth", "source_lineage_breadth"] ->
        "source_breadth_verification"

      true ->
        "verification_recall"
    end
  end

  defp runtime_branch_change_cause(false, _planner_change_kind), do: "none"

  defp runtime_branch_change_cause(true, "strategy_change"), do: "planner_strategy_change"

  defp runtime_branch_change_cause(true, "focus_only"), do: "runtime_redirect_after_focus_change"

  defp runtime_branch_change_cause(true, "none"), do: "runtime_redirect"

  defp normalize_reflect_plan_output(%_{} = output) do
    output
    |> Map.from_struct()
    |> normalize_reflect_plan_output()
  end

  defp normalize_reflect_plan_output(%{} = output) do
    %{
      "focus_query" => Map.get(output, "focus_query") || Map.get(output, :focus_query),
      "needs_consolidation" =>
        Map.get(output, "needs_consolidation") || Map.get(output, :needs_consolidation) || false,
      "answer_ready" =>
        Map.get(output, "answer_ready") || Map.get(output, :answer_ready) || false,
      "reason" => Map.get(output, "reason") || Map.get(output, :reason),
      "refinement_intent" =>
        Map.get(output, "refinement_intent") || Map.get(output, :refinement_intent)
    }
  end

  defp planner_intent_matched_branch?(nil, _branch_type), do: true

  defp planner_intent_matched_branch?("memory_source_breadth", branch_type),
    do: branch_type == "direct_source_first"

  defp planner_intent_matched_branch?("memory_source_then_memory_breadth", branch_type),
    do: branch_type == "source_first_then_memory_retry"

  defp planner_intent_matched_branch?(intent, branch_type)
       when intent in ["source_family_breadth", "source_lineage_breadth"] do
    branch_type in [
      "source_breadth_verification",
      "source_breadth_retry",
      "source_breadth_consolidation"
    ]
  end

  defp planner_intent_matched_branch?("source_provenance_breadth", branch_type),
    do:
      branch_type in [
        "source_provenance_verification",
        "source_provenance_retry",
        "source_provenance_guard"
      ]

  defp planner_intent_matched_branch?(_intent, _branch_type), do: false

  defp estimate_plan_llm_calls(plan_events) do
    Enum.map(plan_events, fn event ->
      phase = Map.get(event, "phase", "plan")
      output = Map.fetch!(event, "output")
      prompt = Map.fetch!(event, "prompt")
      estimate_llm_call(phase, "reflect.plan.v1", prompt, output)
    end)
  end

  defp merge_reflect_recall_results(primary_results, verification_results) do
    (verification_results ++ primary_results)
    |> Enum.uniq_by(& &1["id"])
  end

  defp maybe_structured_reflect_output(llm, query, text, %{"response_schema" => schema})
       when is_map(schema) do
    llm.complete_json_schema(
      %{query: query, text: text},
      Foresight.Prompts.Reflect.Structured.V1.messages(query, text, schema),
      schema,
      []
    )
  end

  defp maybe_structured_reflect_output(_llm, _query, _text, _payload), do: {:ok, nil}

  defp maybe_rewrite_reflect_text(llm, query, text, payload) when is_binary(text) do
    max_tokens = payload["max_tokens"]

    cond do
      not (is_integer(max_tokens) and max_tokens > 0) ->
        {:ok, text, []}

      true ->
        with {:ok, token_count} <- Budget.count_tokens(text),
             true <- token_count > max_tokens do
          rewrite_reflect_text(llm, query, text, max_tokens)
        else
          false -> {:ok, text, []}
          {:error, _reason} -> {:ok, deterministic_trim_to_tokens(text, max_tokens), []}
        end
    end
  end

  defp maybe_rewrite_reflect_text(_llm, _query, text, _payload), do: {:ok, text, []}

  defp validate_reflect_grounding_ids(
         grounded_results,
         mental_models,
         memory_ids,
         mental_model_ids,
         observation_ids
       ) do
    available_memory_ids =
      grounded_results
      |> Enum.reject(&(&1["type"] == "observation"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    available_observation_ids =
      grounded_results
      |> Enum.filter(&(&1["type"] == "observation"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    available_mental_model_ids =
      mental_models
      |> Enum.map(&(&1["id"] || &1[:id]))
      |> MapSet.new()

    valid_memory_ids =
      Enum.filter(List.wrap(memory_ids), &MapSet.member?(available_memory_ids, &1))

    valid_mental_model_ids =
      Enum.filter(List.wrap(mental_model_ids), &MapSet.member?(available_mental_model_ids, &1))

    valid_observation_ids =
      Enum.filter(List.wrap(observation_ids), &MapSet.member?(available_observation_ids, &1))

    %{
      "used_memory_ids" => valid_memory_ids,
      "used_mental_model_ids" => valid_mental_model_ids,
      "used_observation_ids" => valid_observation_ids,
      "rejected_memory_ids" => List.wrap(memory_ids) -- valid_memory_ids,
      "rejected_mental_model_ids" => List.wrap(mental_model_ids) -- valid_mental_model_ids,
      "rejected_observation_ids" => List.wrap(observation_ids) -- valid_observation_ids
    }
  end

  defp filter_grounded_memories(grounded_results, grounding_validation) do
    allowed_ids =
      (grounding_validation["used_memory_ids"] ++ grounding_validation["used_observation_ids"])
      |> MapSet.new()

    Enum.filter(grounded_results, &MapSet.member?(allowed_ids, &1["id"]))
  end

  defp filter_grounded_mental_models(mental_models, grounding_validation) do
    allowed_ids = grounding_validation["used_mental_model_ids"] |> MapSet.new()

    Enum.filter(mental_models, fn model ->
      MapSet.member?(allowed_ids, model["id"] || model[:id])
    end)
  end

  defp no_grounded_evidence?(loop_state) do
    loop_state.grounded_results == [] and loop_state.mental_models == []
  end

  defp reflect_evidence_discipline(
         loop_state,
         grounding_validation,
         directive_compliance,
         opts
       ) do
    used_count =
      grounding_validation["used_memory_ids"]
      |> Kernel.++(grounding_validation["used_observation_ids"])
      |> Kernel.++(grounding_validation["used_mental_model_ids"])
      |> Enum.uniq()
      |> length()

    available_count = length(loop_state.grounded_results) + length(loop_state.mental_models)
    min_grounding_count = Keyword.get(opts, :reflect_min_grounding_count, 1)
    used_diversity_count = grounded_support_diversity_count(loop_state, grounding_validation)
    min_diverse_grounding_count = Keyword.get(opts, :reflect_min_diverse_grounding_count, 1)

    used_provenance_clusters =
      grounded_support_provenance_clusters(loop_state, grounding_validation)

    used_provenance_cluster_count = length(used_provenance_clusters)

    used_source_provenance_clusters =
      grounded_memory_source_provenance_clusters(loop_state, grounding_validation)

    used_source_provenance_cluster_count = length(used_source_provenance_clusters)
    used_source_families = grounded_memory_source_families(loop_state, grounding_validation)
    used_source_family_count = length(used_source_families)
    used_source_lineages = source_lineages(used_source_provenance_clusters)
    used_source_lineage_count = length(used_source_lineages)

    used_all_evidence_families =
      evidence_families(used_provenance_clusters, used_source_families, used_source_lineages)

    used_all_evidence_family_count = length(used_all_evidence_families)

    used_primary_evidence_families =
      grounded_primary_evidence_families(loop_state, grounding_validation)

    used_primary_evidence_family_count = length(used_primary_evidence_families)

    used_memory_evidence_families =
      grounded_memory_evidence_families(loop_state, grounding_validation)

    used_memory_evidence_family_count = length(used_memory_evidence_families)

    used_observation_evidence_families =
      grounded_observation_evidence_families(loop_state, grounding_validation)

    used_observation_evidence_family_count = length(used_observation_evidence_families)

    used_derived_evidence_families =
      used_all_evidence_families -- used_primary_evidence_families

    used_derived_evidence_family_count = length(used_derived_evidence_families)

    {used_evidence_families, used_evidence_family_count} =
      if used_memory_evidence_family_count > 0 do
        {used_memory_evidence_families, used_memory_evidence_family_count}
      else
        {used_primary_evidence_families, used_primary_evidence_family_count}
      end

    min_provenance_cluster_count = Keyword.get(opts, :reflect_min_provenance_cluster_count, 1)

    min_source_provenance_cluster_count =
      Keyword.get(opts, :reflect_min_source_provenance_cluster_count, 0)

    min_source_family_count = Keyword.get(opts, :reflect_min_source_family_count, 0)
    min_source_lineage_count = Keyword.get(opts, :reflect_min_source_lineage_count, 0)
    min_evidence_family_count = Keyword.get(opts, :reflect_min_evidence_family_count, 0)

    evidence_family_details = %{
      "used_evidence_families" => used_evidence_families,
      "used_evidence_family_count" => used_evidence_family_count,
      "used_all_evidence_families" => used_all_evidence_families,
      "used_all_evidence_family_count" => used_all_evidence_family_count,
      "used_primary_evidence_families" => used_primary_evidence_families,
      "used_primary_evidence_family_count" => used_primary_evidence_family_count,
      "used_memory_evidence_families" => used_memory_evidence_families,
      "used_memory_evidence_family_count" => used_memory_evidence_family_count,
      "used_observation_evidence_families" => used_observation_evidence_families,
      "used_observation_evidence_family_count" => used_observation_evidence_family_count,
      "used_derived_evidence_families" => used_derived_evidence_families,
      "used_derived_evidence_family_count" => used_derived_evidence_family_count
    }

    discipline =
      cond do
        available_count > 0 and used_count == 0 ->
          %{
            "status" => "blocked_unverified_answer",
            "reason" => "synthesis produced no valid grounded support",
            "min_grounding_count" => min_grounding_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => 0,
            "used_grounding_diversity_count" => 0,
            "used_provenance_clusters" => [],
            "used_provenance_cluster_count" => 0,
            "used_source_provenance_clusters" => [],
            "used_source_provenance_cluster_count" => 0,
            "used_source_families" => [],
            "used_source_family_count" => 0,
            "used_source_lineages" => [],
            "used_source_lineage_count" => 0,
            "used_evidence_families" => [],
            "used_evidence_family_count" => 0,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "min_source_lineage_count" => min_source_lineage_count,
            "min_evidence_family_count" => min_evidence_family_count
          }

        available_count > 0 and is_integer(min_grounding_count) and min_grounding_count > 1 and
            used_count < min_grounding_count ->
          %{
            "status" => "blocked_thin_grounding",
            "reason" => "validated grounded support did not meet the minimum threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        available_count > 0 and is_integer(min_diverse_grounding_count) and
          min_diverse_grounding_count > 1 and used_diversity_count < min_diverse_grounding_count ->
          %{
            "status" => "blocked_low_support_diversity",
            "reason" => "validated grounded support did not meet the diversity threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        available_count > 0 and is_integer(min_provenance_cluster_count) and
          min_provenance_cluster_count > 1 and
            used_provenance_cluster_count < min_provenance_cluster_count ->
          %{
            "status" => "blocked_low_provenance_diversity",
            "reason" =>
              "validated grounded support did not meet the provenance diversity threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        available_count > 0 and is_integer(min_source_provenance_cluster_count) and
          min_source_provenance_cluster_count > 0 and
            used_source_provenance_cluster_count < min_source_provenance_cluster_count ->
          %{
            "status" => "blocked_low_source_provenance",
            "reason" =>
              "validated grounded support did not meet the raw source provenance threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        available_count > 0 and is_integer(min_source_family_count) and
          min_source_family_count > 0 and used_source_family_count < min_source_family_count ->
          %{
            "status" => "blocked_low_source_family_diversity",
            "reason" =>
              "validated grounded support did not meet the source family breadth threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        available_count > 0 and is_integer(min_source_lineage_count) and
          min_source_lineage_count > 0 and used_source_lineage_count < min_source_lineage_count ->
          %{
            "status" => "blocked_low_source_lineage_diversity",
            "reason" =>
              "validated grounded support did not meet the independent source lineage threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "min_source_lineage_count" => min_source_lineage_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        available_count > 0 and is_integer(min_evidence_family_count) and
          min_evidence_family_count > 0 and
            used_evidence_family_count < min_evidence_family_count ->
          %{
            "status" => "blocked_low_evidence_family_diversity",
            "reason" =>
              "validated grounded support did not meet the overall evidence family breadth threshold",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "min_source_lineage_count" => min_source_lineage_count,
            "min_evidence_family_count" => min_evidence_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }

        true ->
          %{
            "status" => "ok",
            "reason" => directive_compliance["status"] || "grounded_support_present",
            "min_grounding_count" => min_grounding_count,
            "min_diverse_grounding_count" => min_diverse_grounding_count,
            "min_provenance_cluster_count" => min_provenance_cluster_count,
            "min_source_provenance_cluster_count" => min_source_provenance_cluster_count,
            "min_source_family_count" => min_source_family_count,
            "min_source_lineage_count" => min_source_lineage_count,
            "min_evidence_family_count" => min_evidence_family_count,
            "available_grounding_count" => available_count,
            "used_grounding_count" => used_count,
            "used_grounding_diversity_count" => used_diversity_count,
            "used_provenance_clusters" => used_provenance_clusters,
            "used_provenance_cluster_count" => used_provenance_cluster_count,
            "used_source_provenance_clusters" => used_source_provenance_clusters,
            "used_source_provenance_cluster_count" => used_source_provenance_cluster_count,
            "used_source_families" => used_source_families,
            "used_source_family_count" => used_source_family_count,
            "used_source_lineages" => used_source_lineages,
            "used_source_lineage_count" => used_source_lineage_count,
            "used_evidence_families" => used_evidence_families,
            "used_evidence_family_count" => used_evidence_family_count
          }
      end

    merge_evidence_family_details(discipline, evidence_family_details)
  end

  defp evidence_discipline_text(_text, %{"status" => status})
       when status in [
              "blocked_unverified_answer",
              "blocked_thin_grounding",
              "blocked_low_support_diversity",
              "blocked_low_provenance_diversity",
              "blocked_low_source_provenance",
              "blocked_low_source_family_diversity",
              "blocked_low_source_lineage_diversity",
              "blocked_low_evidence_family_diversity"
            ],
       do: no_evidence_reflect_text()

  defp evidence_discipline_text(text, _discipline), do: text

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_unverified_answer"
       }) do
    %{
      "status" => "not_applicable",
      "notes" => "final answer withheld because grounded support was insufficient"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_thin_grounding"
       }) do
    %{
      "status" => "not_applicable",
      "notes" => "final answer withheld because grounded support was insufficient"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_low_support_diversity"
       }) do
    %{
      "status" => "not_applicable",
      "notes" => "final answer withheld because grounded support lacked enough diversity"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_low_provenance_diversity"
       }) do
    %{
      "status" => "not_applicable",
      "notes" => "final answer withheld because grounded support lacked independent provenance"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_low_source_provenance"
       }) do
    %{
      "status" => "not_applicable",
      "notes" => "final answer withheld because grounded support lacked raw source provenance"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_low_source_family_diversity"
       }) do
    %{
      "status" => "not_applicable",
      "notes" => "final answer withheld because grounded support lacked source family breadth"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_low_source_lineage_diversity"
       }) do
    %{
      "status" => "not_applicable",
      "notes" =>
        "final answer withheld because grounded support lacked independent source lineages"
    }
  end

  defp evidence_discipline_directive_compliance(_directive_compliance, %{
         "status" => "blocked_low_evidence_family_diversity"
       }) do
    %{
      "status" => "not_applicable",
      "notes" =>
        "final answer withheld because grounded support lacked overall evidence family breadth"
    }
  end

  defp evidence_discipline_directive_compliance(directive_compliance, _discipline),
    do: directive_compliance

  defp no_evidence_reflect_text do
    "I don't have enough grounded information to answer that."
  end

  defp grounded_support_diversity_count(loop_state, grounding_validation) do
    memory_ids =
      grounding_validation["used_memory_ids"]
      |> Kernel.++(grounding_validation["used_observation_ids"])
      |> MapSet.new()

    memory_fingerprints =
      loop_state.grounded_results
      |> Enum.filter(&MapSet.member?(memory_ids, &1["id"]))
      |> Enum.map(&grounded_support_fingerprint/1)

    model_ids = grounding_validation["used_mental_model_ids"] |> MapSet.new()

    model_fingerprints =
      loop_state.mental_models
      |> Enum.filter(&MapSet.member?(model_ids, &1["id"] || &1[:id]))
      |> Enum.map(&grounded_support_fingerprint/1)

    (memory_fingerprints ++ model_fingerprints)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
  end

  defp grounded_support_provenance_clusters(loop_state, grounding_validation) do
    support_index =
      loop_state.grounded_results
      |> Map.new(&{&1["id"], &1})

    memory_ids =
      grounding_validation["used_memory_ids"]
      |> Kernel.++(grounding_validation["used_observation_ids"])
      |> MapSet.new()

    memory_clusters =
      loop_state.grounded_results
      |> Enum.filter(&MapSet.member?(memory_ids, &1["id"]))
      |> Enum.map(&grounded_support_provenance_cluster(&1, support_index))

    model_ids = grounding_validation["used_mental_model_ids"] |> MapSet.new()

    model_clusters =
      loop_state.mental_models
      |> Enum.filter(&MapSet.member?(model_ids, &1["id"] || &1[:id]))
      |> Enum.map(&grounded_support_provenance_cluster(&1, support_index))

    (memory_clusters ++ model_clusters)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp grounded_memory_source_provenance_clusters(loop_state, grounding_validation) do
    support_index =
      loop_state.grounded_results
      |> Map.new(&{&1["id"], &1})

    loop_state
    |> grounded_memory_supports(grounding_validation)
    |> Enum.map(&grounded_support_provenance_cluster(&1, support_index))
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "source:")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp grounded_memory_source_families(loop_state, grounding_validation) do
    support_index =
      loop_state.grounded_results
      |> Map.new(&{&1["id"], &1})

    loop_state
    |> grounded_memory_supports(grounding_validation)
    |> Enum.map(&grounded_support_source_family(&1, support_index))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_lineages(source_clusters) do
    source_clusters
    |> Enum.map(&source_cluster_ids/1)
    |> Enum.reject(&(MapSet.size(&1) == 0))
    |> merge_overlapping_source_sets()
    |> Enum.map(fn ids ->
      "source_lineage:#{ids |> MapSet.to_list() |> Enum.sort() |> Enum.join("|")}"
    end)
    |> Enum.sort()
  end

  defp evidence_families(source_provenance_clusters, source_families, source_lineages) do
    normalized_source_families =
      Enum.map(source_families, fn
        "document:" <> rest -> "document_family:#{rest}"
        other -> other
      end)

    non_source_families =
      source_provenance_clusters
      |> Enum.reject(&String.starts_with?(&1, "source:"))
      |> Enum.map(fn
        "document:" <> rest -> "document_family:#{rest}"
        other -> "non_source_family:#{other}"
      end)

    (source_lineages ++ normalized_source_families ++ non_source_families)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp available_reflect_evidence_discipline(grounded_results, mental_models, opts) do
    loop_state = %{
      grounded_results: grounded_results,
      mental_models: mental_models
    }

    grounding_validation = %{
      "used_memory_ids" =>
        grounded_results
        |> Enum.reject(&((&1["type"] || &1[:type]) == "observation"))
        |> Enum.map(&(&1["id"] || &1[:id])),
      "used_observation_ids" =>
        grounded_results
        |> Enum.filter(&((&1["type"] || &1[:type]) == "observation"))
        |> Enum.map(&(&1["id"] || &1[:id])),
      "used_mental_model_ids" => Enum.map(mental_models, &(&1["id"] || &1[:id] || &1.external_id))
    }

    reflect_evidence_discipline(
      loop_state,
      grounding_validation,
      %{"status" => "preflight"},
      opts
    )
  end

  defp merge_evidence_family_details(%{} = discipline, %{} = details) do
    Map.merge(discipline, details)
  end

  defp grounded_primary_supports(loop_state, grounding_validation) do
    memory_ids =
      grounding_validation["used_memory_ids"]
      |> Kernel.++(grounding_validation["used_observation_ids"])
      |> MapSet.new()

    Enum.filter(loop_state.grounded_results, &MapSet.member?(memory_ids, &1["id"]))
  end

  defp grounded_primary_evidence_families(loop_state, grounding_validation) do
    support_index =
      loop_state.grounded_results
      |> Map.new(&{&1["id"], &1})

    loop_state
    |> grounded_primary_supports(grounding_validation)
    |> grounded_support_evidence_families(support_index)
  end

  defp grounded_memory_evidence_families(loop_state, grounding_validation) do
    support_index =
      loop_state.grounded_results
      |> Map.new(&{&1["id"], &1})

    loop_state
    |> grounded_memory_supports(grounding_validation)
    |> grounded_support_evidence_families(support_index)
  end

  defp grounded_observation_evidence_families(loop_state, grounding_validation) do
    support_index =
      loop_state.grounded_results
      |> Map.new(&{&1["id"], &1})

    loop_state
    |> grounded_observation_supports(grounding_validation)
    |> grounded_support_evidence_families(support_index)
  end

  defp grounded_support_evidence_families(supports, support_index) do
    provenance_clusters =
      supports
      |> Enum.map(&grounded_support_provenance_cluster(&1, support_index))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    source_provenance_clusters =
      Enum.filter(provenance_clusters, &String.starts_with?(&1, "source:"))

    source_families =
      supports
      |> Enum.map(&grounded_support_source_family(&1, support_index))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    source_lineages = source_lineages(source_provenance_clusters)

    evidence_families(provenance_clusters, source_families, source_lineages)
  end

  defp grounded_memory_supports(loop_state, grounding_validation) do
    memory_ids = grounding_validation["used_memory_ids"] |> MapSet.new()
    Enum.filter(loop_state.grounded_results, &MapSet.member?(memory_ids, &1["id"]))
  end

  defp grounded_observation_supports(loop_state, grounding_validation) do
    observation_ids = grounding_validation["used_observation_ids"] |> MapSet.new()
    Enum.filter(loop_state.grounded_results, &MapSet.member?(observation_ids, &1["id"]))
  end

  defp grounded_support_fingerprint(%{"text" => text, "type" => type}),
    do: "#{type}:#{normalize_support_text(text)}"

  defp grounded_support_fingerprint(%{text: text, type: type}),
    do: "#{type}:#{normalize_support_text(text)}"

  defp grounded_support_fingerprint(document) do
    text = document["text"] || document[:text] || document["content"] || document[:content] || ""
    "mental_model:#{normalize_support_text(text)}"
  end

  defp grounded_support_provenance_cluster(support, support_index) do
    case support_source_ids(support) do
      source_ids when is_list(source_ids) and source_ids != [] ->
        resolved =
          source_ids
          |> resolve_provenance_source_ids(support_index, MapSet.new())
          |> Enum.sort()

        "source:#{Enum.join(resolved, "|")}"

      _ ->
        cond do
          is_binary(support["document_id"]) and support["document_id"] != "" ->
            "document:#{support["document_id"]}"

          is_binary(support["id"]) ->
            "item:#{support["id"]}"

          true ->
            "mental_model:#{support["id"] || support[:id] || inspect(support)}"
        end
    end
  end

  defp grounded_support_source_family(support, support_index) do
    document_ids =
      support
      |> support_document_ids(support_index, MapSet.new())
      |> Enum.sort()

    cond do
      document_ids != [] ->
        "document:#{Enum.join(document_ids, "|")}"

      source_ids = support_source_ids(support) ->
        "source_family:#{Enum.sort(source_ids) |> Enum.join("|")}"

      is_binary(support["document_id"]) and support["document_id"] != "" ->
        "document:#{support["document_id"]}"

      true ->
        nil
    end
  end

  defp support_source_ids(%{"source_fact_ids" => ids}) when is_list(ids) and ids != [], do: ids
  defp support_source_ids(%{"source_memory_ids" => ids}) when is_list(ids) and ids != [], do: ids

  defp support_source_ids(%{"metadata" => %{"source_fact_ids" => ids}})
       when is_list(ids) and ids != [] do
    ids
  end

  defp support_source_ids(%{"metadata" => %{"source_memory_ids" => ids}})
       when is_list(ids) and ids != [] do
    ids
  end

  defp support_source_ids(_support), do: nil

  defp resolve_provenance_source_ids(ids, support_index, visited) do
    ids
    |> Enum.flat_map(fn id ->
      if MapSet.member?(visited, id) do
        [id]
      else
        case Map.get(support_index, id) do
          nil ->
            [id]

          support ->
            case support_source_ids(support) do
              source_ids when is_list(source_ids) and source_ids != [] ->
                resolve_provenance_source_ids(source_ids, support_index, MapSet.put(visited, id))

              _ ->
                [id]
            end
        end
      end
    end)
    |> Enum.uniq()
  end

  defp support_document_ids(support, support_index, visited) do
    document_ids =
      cond do
        is_map(support) and is_binary(support["document_id"]) and support["document_id"] != "" ->
          [support["document_id"]]

        is_map(support) and is_binary(support["id"]) and Map.has_key?(support, "original_text") ->
          [support["id"]]

        true ->
          []
      end

    case support_source_ids(support) do
      ids when is_list(ids) and ids != [] ->
        (document_ids ++ resolve_source_document_ids(ids, support_index, visited))
        |> Enum.reject(&(is_nil(&1) or &1 == ""))
        |> Enum.uniq()

      _ ->
        document_ids |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq()
    end
  end

  defp source_cluster_ids("source:" <> rest) do
    rest
    |> String.split("|", trim: true)
    |> MapSet.new()
  end

  defp source_cluster_ids(_cluster), do: MapSet.new()

  defp merge_overlapping_source_sets(sets) do
    Enum.reduce(sets, [], fn set, acc ->
      {overlapping, disjoint} =
        Enum.split_with(acc, fn existing -> not MapSet.disjoint?(existing, set) end)

      merged =
        Enum.reduce(overlapping, set, fn existing, current ->
          MapSet.union(current, existing)
        end)

      [merged | disjoint]
    end)
  end

  defp resolve_source_document_ids(ids, support_index, visited) do
    ids
    |> Enum.flat_map(fn id ->
      if MapSet.member?(visited, id) do
        []
      else
        case Map.get(support_index, id) do
          nil -> []
          support -> support_document_ids(support, support_index, MapSet.put(visited, id))
        end
      end
    end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp normalize_support_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_support_text(_text), do: ""

  defp clean_reflect_answer_text(text) when is_binary(text) do
    text
    |> String.replace(@leaked_json_suffix, "")
    |> String.replace(@leaked_json_object, "")
    |> String.replace(@trailing_ids_pattern, "")
    |> String.trim()
    |> case do
      "" -> text
      cleaned -> cleaned
    end
  end

  defp clean_reflect_answer_text(text), do: text

  defp rewrite_reflect_text(llm, query, text, max_tokens) do
    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["text"],
      "properties" => %{"text" => %{"type" => "string"}}
    }

    messages = [
      %{
        role: :system,
        content:
          "Rewrite the answer so it fits within the requested token budget while preserving the most important grounded facts. Return JSON only."
      },
      %{
        role: :user,
        content: """
        Query: #{query}
        Token budget: #{max_tokens}

        Answer to rewrite:
        #{text}
        """
      }
    ]

    case llm.complete_json_schema(%{query: query, text: text}, messages, schema, []) do
      {:ok, %{"text" => rewritten}} when is_binary(rewritten) ->
        final_text = enforce_token_budget(rewritten, max_tokens)

        {:ok, final_text,
         [
           estimate_rewrite_llm_call(messages, final_text, max_tokens, false)
         ]}

      _other ->
        {:ok, deterministic_trim_to_tokens(text, max_tokens),
         [
           estimate_rewrite_llm_call(
             messages,
             deterministic_trim_to_tokens(text, max_tokens),
             max_tokens,
             true
           )
         ]}
    end
  end

  defp enforce_token_budget(text, max_tokens) do
    case Budget.count_tokens(text) do
      {:ok, token_count} when token_count <= max_tokens -> text
      _ -> deterministic_trim_to_tokens(text, max_tokens)
    end
  end

  defp deterministic_trim_to_tokens(text, max_tokens)
       when is_integer(max_tokens) and max_tokens > 0 do
    words = String.split(text, ~r/\s+/, trim: true)

    {kept_words, _used_tokens} =
      Enum.reduce_while(words, {[], 0}, fn word, {kept, _used_tokens} ->
        candidate =
          case kept do
            [] -> word
            _ -> Enum.join(kept ++ [word], " ")
          end

        case Budget.count_tokens(candidate) do
          {:ok, token_count} when token_count <= max_tokens ->
            {:cont, {kept ++ [word], token_count}}

          _ ->
            {:halt, {kept, 0}}
        end
      end)

    Enum.join(kept_words, " ")
  end

  defp deterministic_trim_to_tokens(text, _max_tokens), do: text

  defp maybe_structured_llm_trace(%{"response_schema" => schema}, query, text, structured_output)
       when is_map(schema) and not is_nil(structured_output) do
    [
      estimate_messages_llm_call(
        "structured_output",
        "reflect.structured.v1",
        Foresight.Prompts.Reflect.Structured.V1.messages(query, text, schema),
        structured_output
      )
    ]
  end

  defp maybe_structured_llm_trace(_payload, _query, _text, _structured_output), do: []

  defp timed_ms(fun) when is_function(fun, 0) do
    started_at_ms = monotonic_ms()
    {fun.(), monotonic_ms() - started_at_ms}
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp estimate_rewrite_llm_call(messages, output_text, max_tokens, fallback?) do
    estimate_messages_llm_call("final_rewrite", "reflect.rewrite.v1", messages, %{
      "text" => output_text
    })
    |> Map.put("max_tokens", max_tokens)
    |> maybe_put("fallback", fallback?)
  end

  defp estimate_llm_call(phase, prompt_name, prompt_struct, output) do
    estimate_messages_llm_call(
      phase,
      prompt_name,
      messages_for_prompt(prompt_name, prompt_struct),
      output
    )
  end

  defp estimate_messages_llm_call(phase, prompt_name, messages, output) do
    %{
      "phase" => phase,
      "prompt" => prompt_name,
      "input_tokens" => safe_count_messages_tokens(messages),
      "output_tokens" => safe_count_term_tokens(output)
    }
  end

  defp messages_for_prompt("reflect.plan.v1", prompt_struct),
    do: Foresight.Prompts.Reflect.Plan.V1.messages(prompt_struct)

  defp messages_for_prompt("reflect.v1", prompt_struct),
    do: Foresight.Prompts.Reflect.V1.messages(prompt_struct)

  defp safe_count_messages_tokens(messages) do
    messages
    |> Enum.map_join("\n\n", &to_string(Map.get(&1, :content) || Map.get(&1, "content") || ""))
    |> safe_count_string_tokens()
  end

  defp safe_count_term_tokens(term) when is_binary(term), do: safe_count_string_tokens(term)

  defp safe_count_term_tokens(term) do
    term
    |> inspect(pretty: false, limit: :infinity)
    |> safe_count_string_tokens()
  end

  defp safe_count_string_tokens(text) do
    case Budget.count_tokens(text) do
      {:ok, count} -> count
      _ -> 0
    end
  end

  defp usage_from_llm_calls(llm_calls) do
    input_tokens = Enum.reduce(llm_calls, 0, &(&1["input_tokens"] + &2))
    output_tokens = Enum.reduce(llm_calls, 0, &(&1["output_tokens"] + &2))

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => input_tokens + output_tokens
    }
  end

  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reflect_tool_calls(tool_calls, payload) do
    include_output? = get_in(payload, ["include", "tool_calls", "output"]) != false

    Enum.map(tool_calls, fn tool_call ->
      if include_output? do
        tool_call
      else
        Map.delete(tool_call, "output")
      end
    end)
  end

  defp reflect_observations(ctx, payload) do
    case list_memories(
           ctx,
           %{
             "type" => "observation",
             "tags" => payload["tags"],
             "tags_match" => Map.get(payload, "tags_match", "any"),
             "scope_keys" => reflect_scope_keys(payload),
             "limit" => 5
           },
           []
         ) do
      {:ok, %{"items" => items}} ->
        pending = pending_consolidation_count(ctx.bank)

        %{
          "query" => payload["query"],
          "count" => length(items),
          "observations" => Enum.map(items, &observation_item_to_based_on/1),
          "is_stale" => pending > 0,
          "freshness" => observation_freshness(pending)
        }

      _ ->
        %{
          "query" => payload["query"],
          "count" => 0,
          "observations" => [],
          "is_stale" => false,
          "freshness" => "up_to_date"
        }
    end
  end

  defp observation_item_to_based_on(item) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "mentioned_at" => item["date"] || item["mentioned_at"],
      "type" => item["type"],
      "source_fact_ids" =>
        item["source_fact_ids"] ||
          get_in(item, ["metadata", "source_fact_ids"]) ||
          item["source_memory_ids"] || []
    }
  end

  defp merge_grounding_results(observations, recall_results) do
    (observations ++ recall_results)
    |> Enum.uniq_by(& &1["id"])
  end

  defp maybe_expand_reflect_results(bank_id, recall_results, payload, iteration) do
    should_expand? =
      to_string(Map.get(payload, "budget", "low")) == "high" and
        Enum.any?(recall_results, &is_binary(&1["document_id"]))

    if should_expand? do
      expanded_results =
        Agent.get(__MODULE__, fn state ->
          Enum.map(recall_results, fn result ->
            document =
              Map.get(state.documents, {bank_id, result["document_id"]}) ||
                Map.get(state.mental_models, {bank_id, result["document_id"]})

            case document do
              %{} = document ->
                Map.put(result, "expanded_context", %{
                  "depth" => "document",
                  "document_id" => result["document_id"],
                  "document_text" => document["original_text"] || result["text"]
                })

              nil ->
                result
            end
          end)
        end)

      expanded_ids =
        expanded_results
        |> Enum.filter(&is_map(&1["expanded_context"]))
        |> Enum.map(& &1["id"])

      tool_call =
        if expanded_ids == [] do
          nil
        else
          %{
            "iteration" => min(3, iteration),
            "phase" => "auto_expand",
            "tool" => "expand",
            "input" => %{
              "memory_ids" => expanded_ids,
              "depth" => "document",
              "bank_id" => bank_id
            },
            "output" => %{
              "expanded_count" => length(expanded_ids),
              "document_ids" =>
                expanded_results
                |> Enum.filter(&(&1["id"] in expanded_ids))
                |> Enum.map(& &1["document_id"])
                |> Enum.uniq()
            }
          }
        end

      {expanded_results, tool_call}
    else
      {recall_results, nil}
    end
  end

  defp reflect_max_iterations(payload, opts) do
    base_max_iterations = Keyword.get(opts, :reflect_max_iterations, 10)

    multiplier =
      case to_string(Map.get(payload, "budget", "low")) do
        "low" -> 0.5
        "high" -> 2.0
        _ -> 1.0
      end

    max(1, trunc(base_max_iterations * multiplier))
  end

  defp pending_consolidation_count(bank_id) do
    Agent.get(__MODULE__, fn state ->
      last_consolidated_at =
        state.memory_units
        |> Enum.filter(&(&1["bank_id"] == bank_id and &1["type"] == "observation"))
        |> Enum.map(& &1["consolidated_at"])
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
        |> List.last()

      state.memory_units
      |> Enum.filter(fn unit ->
        unit_timestamp = unit["inserted_at"] || unit["mentioned_at"]

        unit["bank_id"] == bank_id and unit["type"] in ["world", "experience"] and
          (is_nil(last_consolidated_at) or unit_timestamp > last_consolidated_at)
      end)
      |> length()
    end)
  end

  defp observation_freshness(0), do: "up_to_date"
  defp observation_freshness(pending) when pending < 10, do: "slightly_stale"
  defp observation_freshness(_pending), do: "stale"

  defp maybe_list(nil), do: []
  defp maybe_list(value), do: [value]

  defp consolidation_payload(payload) do
    %{
      "scope_keys" => reflect_scope_keys(payload)
    }
  end

  defp reflect_scope_keys(payload) do
    if List.wrap(payload["tags"]) == [] and Map.get(payload, "observation_scopes", %{}) == %{} do
      []
    else
      requested_scopes(%{
        "tag_scopes" => [
          %{
            "tags" => List.wrap(payload["tags"]),
            "observation_scopes" => Map.get(payload, "observation_scopes", %{})
          }
        ]
      })
    end
  end

  defp maybe_filter_scope_keys(units, nil), do: units
  defp maybe_filter_scope_keys(units, []), do: units

  defp maybe_filter_scope_keys(units, scope_keys) when is_list(scope_keys) do
    Enum.filter(units, fn unit ->
      scope_key_for_unit(unit) in scope_keys
    end)
  end

  defp active_mental_models(bank_id, payload) do
    Agent.get(__MODULE__, fn state ->
      tags = List.wrap(payload["tags"])

      state.mental_models
      |> Map.values()
      |> Enum.filter(&(&1["bank_id"] == bank_id))
      |> Enum.filter(fn model ->
        tags == [] or model["tags"] == [] or Enum.any?(model["tags"], &(&1 in tags))
      end)
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(fn model ->
        %{
          "id" => model["id"],
          "title" => model["title"],
          "text" => model["original_text"],
          "tags" => model["tags"]
        }
      end)
    end)
  end

  defp active_directives(bank_id, payload) do
    Agent.get(__MODULE__, fn state ->
      state.directives
      |> Map.values()
      |> Enum.filter(&(&1["bank_id"] == bank_id and Map.get(&1, "is_active", true)))
      |> Enum.filter(&directive_matches_tags?(&1, payload))
      |> Enum.sort_by(fn directive -> {-Map.get(directive, "priority", 0), directive["name"]} end)
    end)
  end

  defp directive_matches_tags?(directive, %{"tags" => tags}) when is_list(tags) and tags != [] do
    Map.get(directive, "tags", []) == [] or Enum.any?(directive["tags"], &(&1 in tags))
  end

  defp directive_matches_tags?(_directive, _payload), do: true

  defp based_on_memory(result) do
    %{
      "id" => result["id"],
      "text" => result["text"],
      "mentioned_at" => result["mentioned_at"],
      "type" => result["type"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp recall_trace(
         query,
         payload,
         results,
         strategy_trace,
         strategy_items,
         fused_items,
         rerank_candidates,
         reranked_units,
         boosted_units,
         final_units
       ) do
    rank_context =
      recall_rank_context(
        fused_items,
        rerank_candidates,
        reranked_units,
        boosted_units,
        final_units
      )

    %{
      "query" => query,
      "num_results" => length(results),
      "time_seconds" => 0.0,
      "strategies" => strategy_trace,
      "entry_points" => recall_entry_points(strategy_items),
      "retrieval_results" => recall_retrieval_results(strategy_items),
      "rrf_merged" => recall_ranked_stage(fused_items, "rrf_score", "rrf", rank_context),
      "rerank_candidates" =>
        recall_ranked_stage(rerank_candidates, "rrf_score", "rerank_candidates", rank_context),
      "reranked" => recall_ranked_stage(reranked_units, "rerank_score", "reranked", rank_context),
      "boosted" => recall_ranked_stage(boosted_units, "boosted_score", "boosted", rank_context),
      "final_results" => recall_final_results(results, rank_context),
      "visits" => recall_visits(final_units, rank_context),
      "summary" =>
        recall_summary(
          payload,
          strategy_trace,
          fused_items,
          rerank_candidates,
          reranked_units,
          boosted_units,
          final_units
        ),
      "displacement" => recall_displacement_summary(rank_context, strategy_trace),
      "pruned" =>
        recall_pruned(fused_items, rerank_candidates, reranked_units, boosted_units, final_units),
      "fusion" => fake_trace_fusion(),
      "reranker" => %{"active" => true, "count" => length(reranked_units)}
    }
  end

  # Mirrors storage/ecto.ex recall_trace_fusion/1. Hardcoding "rrf" here meant the double
  # kept reporting the old default after the default changed, and store_test.exs asserted
  # that stale value — a test passing because two places were wrong in the same way.
  defp fake_trace_fusion do
    opts =
      Foresight.Recall.FusionConfig.resolve(
        Application.get_env(:foresight, :recall_fusion, []),
        nil
      )

    base = %{"algorithm" => to_string(Keyword.fetch!(opts, :fusion)), "k" => 60}

    case Keyword.fetch!(opts, :fusion) do
      :rrf -> base
      _ -> Map.put(base, "normalization", to_string(Keyword.fetch!(opts, :normalization)))
    end
  end

  defp recall_entry_points(items) do
    items
    |> Enum.reduce(%{}, fn {strategy, strategy_items}, acc ->
      strategy_items
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {item, strategy_rank}, inner_acc ->
        score = strategy_score(item, strategy)
        current = Map.get(inner_acc, item["id"])

        if is_nil(current) or score > current["similarity_score"] do
          Map.put(inner_acc, item["id"], %{
            "node_id" => item["id"],
            "text" => item["content"],
            "similarity_score" => score,
            "source_strategy" => strategy,
            "native_score" => score,
            "source_rank" => strategy_rank
          })
        else
          inner_acc
        end
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn entry -> {-entry["similarity_score"], entry["node_id"]} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, rank} -> Map.put(entry, "rank", rank) end)
  end

  defp recall_retrieval_results(items) do
    items
    |> normalize_strategy_groups()
    |> Map.new(fn {name, strategy_items} ->
      filtered =
        strategy_items
        |> normalize_strategy_item_list()
        |> Enum.with_index(1)
        |> Enum.map(fn {item, rank} ->
          %{
            "node_id" => item["id"],
            "text" => item["content"],
            "rank" => rank,
            "score" => strategy_score(item, name)
          }
          |> Map.merge(recall_trace_evidence(item, name))
        end)

      {name, filtered}
    end)
  end

  defp normalize_strategy_groups(groups) when is_map(groups), do: groups

  defp normalize_strategy_groups(groups) when is_list(groups) do
    if Enum.all?(groups, &match?({key, _value} when is_binary(key), &1)) do
      Map.new(groups)
    else
      %{"unknown" => groups}
    end
  end

  defp normalize_strategy_item_list(items) when is_list(items), do: items

  defp normalize_strategy_item_list(items) when is_map(items) do
    items
    |> Map.values()
    |> List.flatten()
  end

  defp recall_ranked_stage(items, score_key, stage, rank_context) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, rank} ->
      strategy_contributions = Map.get(item, "strategy_contributions", %{})

      %{
        "node_id" => item["id"],
        "text" => item["content"],
        "rank" => rank,
        "score" => Map.get(item, score_key, 0.0),
        "strategy_contributions" => strategy_contributions,
        "movement" => recall_stage_movement(item, stage, rank_context),
        "fusion" => %{
          "winning_strategy" => winning_strategy(strategy_contributions),
          "strategy_count" => map_size(strategy_contributions),
          "top_contribution" => top_contribution(strategy_contributions),
          "contributions" => Map.get(item, "strategy_contribution_details", %{})
        }
      }
      |> maybe_put_boost_trace(item)
    end)
  end

  defp maybe_put_boost_trace(entry, item) do
    case Map.get(item, "boosts") do
      boosts when is_map(boosts) and boosts != %{} -> Map.put(entry, "boosts", boosts)
      _ -> entry
    end
  end

  defp recall_final_results(results, rank_context) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {result, rank} ->
      %{
        "node_id" => result["id"],
        "text" => result["text"],
        "type" => result["type"],
        "rank" => rank,
        "movement" => recall_stage_movement(result, "final", rank_context),
        "boosts" => final_stage_boost_trace(result)
      }
    end)
  end

  defp recall_visits(final_units, rank_context) do
    final_units
    |> Enum.with_index(1)
    |> Enum.map(fn {item, rank} ->
      %{
        "node_id" => item["id"],
        "text" => item["content"],
        "final_rank" => rank,
        "movement" => recall_stage_movement(item, "final", rank_context),
        "evidence" => recall_visit_evidence(item),
        "weights" => %{
          "rrf_score" => Map.get(item, "rrf_score", 0.0),
          "rerank_score" => Map.get(item, "rerank_score", 0.0),
          "boosted_score" => Map.get(item, "boosted_score", 0.0),
          "recency" => get_in(item, ["boosts", "recency"]) || 0.0,
          "recency_contribution" => get_in(item, ["boosts", "recency_contribution"]) || 0.0,
          "temporal" => get_in(item, ["boosts", "temporal"]) || 0.0,
          "temporal_contribution" => get_in(item, ["boosts", "temporal_contribution"]) || 0.0,
          "proof" => get_in(item, ["boosts", "proof"]) || 0.0,
          "proof_contribution" => get_in(item, ["boosts", "proof_contribution"]) || 0.0,
          "source_expansion" => get_in(item, ["boosts", "source_expansion"]) || 0.0,
          "source_expansion_contribution" =>
            get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0,
          "source_novel_only" => get_in(item, ["boosts", "source_novel_only"]) || 0.0,
          "source_novel_only_contribution" =>
            get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0
        }
      }
    end)
  end

  defp final_stage_boost_trace(item) do
    case Map.get(item, "boosts") do
      boosts when is_map(boosts) and boosts != %{} -> boosts
      _ -> %{}
    end
  end

  defp recall_trace_evidence(item, "graph") do
    %{
      "hop" => Map.get(item, "graph_hop", 0),
      "seed_overlap_count" => Map.get(item, "graph_seed_overlap_count", 0),
      "frontier_overlap_count" => Map.get(item, "graph_frontier_overlap_count", 0),
      "source_seed" => Map.get(item, "graph_source_seed", false),
      "source_overlap_count" => Map.get(item, "graph_source_overlap_count", 0),
      "source_traversal_score" => Map.get(item, "graph_source_traversal_score", 0.0),
      "source_shortfall_type" => Map.get(item, "graph_source_shortfall_type"),
      "source_shortfall_bonus" => Map.get(item, "graph_source_shortfall_bonus", 0.0),
      "source_frontier_bonus" => Map.get(item, "graph_source_frontier_bonus", 0.0),
      "source_frontier_group" => Map.get(item, "graph_source_frontier_group"),
      "source_frontier_novel_count" => Map.get(item, "graph_source_frontier_novel_count", 0),
      "source_frontier_priority" => Map.get(item, "graph_source_frontier_priority"),
      "source_expansion" => Map.get(item, "graph_source_expansion", false)
    }
  end

  defp recall_trace_evidence(item, "temporal") do
    %{
      "hop" => Map.get(item, "temporal_hop", 0),
      "source_overlap_count" => item |> Map.get("temporal_source_overlap", []) |> length(),
      "seed_score" => Map.get(item, "temporal_seed_score", 0.0),
      "semantic_score" => Map.get(item, "temporal_semantic_score", 0.0)
    }
  end

  defp recall_trace_evidence(_item, _name), do: %{}

  defp recall_rank_context(
         fused_items,
         rerank_candidates,
         reranked_units,
         boosted_units,
         final_units
       ) do
    %{
      "rrf" => rank_index(fused_items),
      "rerank_candidates" => rank_index(rerank_candidates),
      "reranked" => rank_index(reranked_units),
      "boosted" => rank_index(boosted_units),
      "final" => rank_index(final_units)
    }
  end

  defp rank_index(items) do
    items
    |> Enum.with_index(1)
    |> Map.new(fn {item, rank} -> {item["id"], %{"rank" => rank, "item" => item}} end)
  end

  defp recall_stage_movement(item, stage, rank_context) do
    node_id = item["id"]
    current_rank = rank_context |> get_in([stage, node_id]) |> rank_entry_rank()
    previous_stage = previous_stage(stage)

    previous_rank =
      if previous_stage,
        do: rank_context |> get_in([previous_stage, node_id]) |> rank_entry_rank(),
        else: nil

    %{
      "from_stage" => previous_stage,
      "from_rank" => previous_rank,
      "to_stage" => stage,
      "to_rank" => current_rank,
      "delta" => rank_delta(previous_rank, current_rank),
      "explanations" => recall_stage_explanations(item, stage, previous_rank, current_rank)
    }
  end

  defp previous_stage("rrf"), do: nil
  defp previous_stage("rerank_candidates"), do: "rrf"
  defp previous_stage("reranked"), do: "rerank_candidates"
  defp previous_stage("boosted"), do: "reranked"
  defp previous_stage("final"), do: "boosted"

  defp rank_delta(nil, _current_rank), do: nil
  defp rank_delta(previous_rank, current_rank), do: previous_rank - current_rank

  defp recall_displacement_summary(rank_context, strategy_trace) do
    %{
      "rerank_promotions" => displacement_count(rank_context, "reranked", &(&1 > 0)),
      "rerank_demotions" => displacement_count(rank_context, "reranked", &(&1 < 0)),
      "rerank_explanations" => explanation_rollup(rank_context, "reranked"),
      "boost_promotions" => displacement_count(rank_context, "boosted", &(&1 > 0)),
      "boost_demotions" => displacement_count(rank_context, "boosted", &(&1 < 0)),
      "boost_explanations" => explanation_rollup(rank_context, "boosted"),
      "final_explanations" => explanation_rollup(rank_context, "final"),
      "source_frontier_breadth_boosted" =>
        explanation_count(rank_context, "boosted", "source_frontier_breadth"),
      "source_frontier_breadth_retained" =>
        explanation_count(rank_context, "final", "source_frontier_breadth"),
      "memory_breadth_boosted" =>
        explanation_count(rank_context, "boosted", "memory_breadth_boost"),
      "memory_breadth_retained" =>
        explanation_count(rank_context, "final", "memory_breadth_retained"),
      "final_trimmed_out" => map_size(rank_context["boosted"]) - map_size(rank_context["final"]),
      "source_expansion_windowed_out" =>
        source_expansion_stage_delta(rank_context, "rrf", "rerank_candidates"),
      "source_expansion_boosted_windowed_out" =>
        source_expansion_boosted_stage_delta(rank_context, "rrf", "rerank_candidates"),
      "source_novel_only_filtered" => source_novel_only_filtered_count(strategy_trace),
      "source_novel_only_windowed_out" =>
        source_novel_only_stage_delta(rank_context, "rrf", "rerank_candidates"),
      "source_expansion_trimmed_out" =>
        source_expansion_stage_delta(rank_context, "boosted", "final"),
      "source_expansion_boosted_trimmed_out" =>
        source_expansion_boosted_stage_delta(rank_context, "boosted", "final"),
      "source_novel_only_trimmed_out" =>
        source_novel_only_stage_delta(rank_context, "boosted", "final"),
      "source_novel_only_retained" =>
        explanation_count(rank_context, "final", "source_novel_only_pressure")
    }
  end

  defp source_expansion_stage_delta(rank_context, from_stage, to_stage) do
    from_ids = rank_context |> Map.get(from_stage, %{}) |> Map.keys() |> MapSet.new()
    to_ids = rank_context |> Map.get(to_stage, %{}) |> Map.keys() |> MapSet.new()
    Enum.count(from_ids, &(not MapSet.member?(to_ids, &1)))
  end

  defp source_expansion_boosted_stage_delta(rank_context, from_stage, to_stage) do
    from_items =
      rank_context
      |> Map.get(from_stage, %{})
      |> Map.values()
      |> Enum.map(&rank_entry_item/1)

    to_ids = rank_context |> Map.get(to_stage, %{}) |> Map.keys() |> MapSet.new()

    Enum.count(from_items, fn item ->
      not MapSet.member?(to_ids, item["id"]) and
        (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
    end)
  end

  defp source_novel_only_filtered_count(strategy_trace) do
    strategy_trace
    |> get_in(["graph", "diagnostics", "frontier_filtered_out"])
    |> List.wrap()
    |> Enum.count(fn record ->
      "source_novel_only_filter" in Map.get(record, "reasons", [Map.get(record, "reason")])
    end)
  end

  defp source_novel_only_stage_delta(rank_context, from_stage, to_stage) do
    from_items =
      rank_context
      |> Map.get(from_stage, %{})
      |> Map.values()
      |> Enum.map(&rank_entry_item/1)

    to_ids = rank_context |> Map.get(to_stage, %{}) |> Map.keys() |> MapSet.new()

    Enum.count(from_items, fn item ->
      not MapSet.member?(to_ids, item["id"]) and source_novel_only_item?(item)
    end)
  end

  defp rank_entry_rank(%{"rank" => rank}), do: rank
  defp rank_entry_rank(rank) when is_integer(rank), do: rank
  defp rank_entry_rank(_), do: nil

  defp rank_entry_item(%{"item" => item}), do: item
  defp rank_entry_item(item), do: item

  defp recall_stage_explanations(_item, "rrf", _previous_rank, _current_rank), do: []

  defp recall_stage_explanations(item, "rerank_candidates", previous_rank, current_rank) do
    []
    |> maybe_add_overlap_explanation(item)
    |> maybe_add_source_expansion_explanation(item, "source_expansion_admitted_to_rerank")
    |> maybe_add_source_novel_only_explanation(item, "source_novel_only_pressure")
    |> maybe_add_rank_direction(previous_rank, current_rank, "admitted_to_rerank_window")
  end

  defp recall_stage_explanations(item, "reranked", previous_rank, current_rank) do
    []
    |> maybe_add_overlap_explanation(item)
    |> maybe_add_rank_direction(
      previous_rank,
      current_rank,
      "reranker_disagreement",
      "reranker_agreement"
    )
  end

  defp recall_stage_explanations(item, "boosted", previous_rank, current_rank) do
    []
    |> maybe_add_overlap_explanation(item)
    |> maybe_add_source_expansion_explanation(item, "source_expansion_boost")
    |> maybe_add_memory_breadth_explanation(item, "memory_breadth_boost")
    |> maybe_add_boost_explanation(get_in(item, ["boosts", "recency_contribution"]), "recency")
    |> maybe_add_boost_explanation(get_in(item, ["boosts", "temporal_contribution"]), "temporal")
    |> maybe_add_boost_explanation(get_in(item, ["boosts", "proof_contribution"]), "proof")
    |> maybe_add_rank_direction(previous_rank, current_rank, "boost_demoted", "boost_promoted")
  end

  defp recall_stage_explanations(item, "final", previous_rank, current_rank) do
    []
    |> maybe_add_overlap_explanation(item)
    |> maybe_add_source_expansion_explanation(item, "source_expansion_retained")
    |> maybe_add_source_novel_only_explanation(item, "source_novel_only_pressure")
    |> maybe_add_memory_breadth_explanation(item, "memory_breadth_retained")
    |> maybe_add_rank_direction(
      previous_rank,
      current_rank,
      "higher_ranked_items_kept",
      "higher_ranked_items_trimmed"
    )
  end

  defp maybe_add_overlap_explanation(explanations, item) do
    if map_size(Map.get(item, "strategy_contributions", %{})) <= 1 do
      ["limited_strategy_overlap" | explanations]
    else
      explanations
    end
  end

  defp maybe_add_boost_explanation(explanations, value, label)
       when is_number(value) and value > 0 do
    ["#{label}_boost" | explanations]
  end

  defp maybe_add_boost_explanation(explanations, value, label)
       when is_number(value) and value < 0 do
    ["#{label}_penalty" | explanations]
  end

  defp maybe_add_boost_explanation(explanations, _value, _label), do: explanations

  defp maybe_add_memory_breadth_explanation(explanations, item, label) do
    case get_in(item, ["boosts", "memory_breadth_contribution"]) do
      value when is_number(value) and value > 0.0 ->
        [label | explanations]

      _ ->
        explanations
    end
  end

  defp maybe_add_source_expansion_explanation(explanations, item, label) do
    if source_expansion_item?(item) do
      source_frontier_bonus =
        case Map.get(item, "graph_source_frontier_bonus") do
          value when is_number(value) -> value
          _ -> inferred_source_frontier_bonus(item)
        end

      explanations =
        if source_frontier_bonus > 0.0 do
          ["source_frontier_breadth" | explanations]
        else
          explanations
        end

      [label | explanations]
    else
      explanations
    end
  end

  defp maybe_add_source_novel_only_explanation(explanations, item, label) do
    if source_novel_only_item?(item), do: [label | explanations], else: explanations
  end

  defp inferred_source_frontier_bonus(item) do
    bonus =
      cond do
        is_number(Map.get(item, "source_expansion_score")) and
            is_number(Map.get(item, "graph_source_traversal_score")) ->
          Map.get(item, "source_expansion_score", 0.0) -
            Map.get(item, "graph_source_traversal_score", 0.0)

        is_number(Map.get(item, "source_expansion_score")) and
            is_number(Map.get(item, "graph_score")) ->
          Map.get(item, "source_expansion_score", 0.0) - Map.get(item, "graph_score", 0.0)

        is_number(
          get_in(item, ["strategy_contribution_details", "source_expansion", "native_score"])
        ) and
            is_number(get_in(item, ["strategy_contribution_details", "graph", "native_score"])) ->
          get_in(item, ["strategy_contribution_details", "source_expansion", "native_score"]) -
            get_in(item, ["strategy_contribution_details", "graph", "native_score"])

        true ->
          source_native =
            get_in(item, ["fusion", "contributions", "source_expansion", "native_score"]) || 0.0

          graph_native = get_in(item, ["fusion", "contributions", "graph", "native_score"]) || 0.0
          source_native - graph_native
      end

    if bonus > 0.0, do: bonus, else: 0.0
  end

  defp maybe_add_rank_direction(
         explanations,
         previous_rank,
         current_rank,
         negative_label,
         positive_label \\ nil
       )

  defp maybe_add_rank_direction(
         explanations,
         previous_rank,
         current_rank,
         negative_label,
         positive_label
       )
       when is_integer(previous_rank) and is_integer(current_rank) do
    cond do
      previous_rank < current_rank ->
        [negative_label | explanations]

      previous_rank > current_rank and is_binary(positive_label) ->
        [positive_label | explanations]

      true ->
        explanations
    end
  end

  defp maybe_add_rank_direction(
         explanations,
         _previous_rank,
         _current_rank,
         _negative_label,
         _positive_label
       ),
       do: explanations

  defp displacement_count(rank_context, stage, predicate) do
    rank_context
    |> Map.get(stage, %{})
    |> Enum.count(fn {node_id, _rank} ->
      case recall_stage_movement(%{"id" => node_id}, stage, rank_context)["delta"] do
        delta when is_integer(delta) -> predicate.(delta)
        _ -> false
      end
    end)
  end

  defp explanation_rollup(rank_context, stage) do
    rank_context
    |> Map.get(stage, %{})
    |> Enum.reduce(%{}, fn {node_id, _rank}, acc ->
      recall_stage_movement(%{"id" => node_id}, stage, rank_context)["explanations"]
      |> Enum.reduce(acc, fn explanation, inner_acc ->
        Map.update(inner_acc, explanation, 1, &(&1 + 1))
      end)
    end)
  end

  defp explanation_count(rank_context, stage, explanation) do
    rank_context
    |> Map.get(stage, %{})
    |> Enum.count(fn {node_id, _rank} ->
      explanation in recall_stage_movement(%{"id" => node_id}, stage, rank_context)[
        "explanations"
      ]
    end)
  end

  defp strategy_rollups(strategy_trace) do
    Map.new(strategy_trace, fn {name, trace} ->
      diagnostics = Map.get(trace, "diagnostics", %{})
      mode = strategy_mode(trace)
      outcome = strategy_outcome(trace)
      state_reason = strategy_state_reason(name, outcome)
      underlying_reasons = strategy_underlying_reasons(outcome, diagnostics, trace)
      reasons = strategy_outcome_reasons(name, outcome, diagnostics, trace)
      state_reason_counts = strategy_reason_counts([state_reason])
      underlying_reason_counts = strategy_reason_counts(underlying_reasons)
      pre_filter_count = Map.get(trace, "pre_filter_count", Map.get(trace, "count", 0))
      filtered_out_count = Map.get(trace, "filtered_out_count", 0)
      filtered_out_reason_counts = Map.get(trace, "filtered_out_reason_counts", %{})

      {name,
       %{
         "active" => Map.get(trace, "active", false),
         "mode" => mode,
         "outcome" => outcome,
         "count" => Map.get(trace, "count", 0),
         "pre_filter_count" => pre_filter_count,
         "filtered_out_count" => filtered_out_count,
         "filtered_out_reason_counts" => filtered_out_reason_counts,
         "contributed_count" => trace |> Map.get("contributed", []) |> length(),
         "state_reason" => state_reason,
         "underlying_reasons" => underlying_reasons,
         "state_reason_counts" => state_reason_counts,
         "underlying_reason_counts" => underlying_reason_counts,
         "non_contribution_reasons" => reasons,
         "non_contribution_reason_counts" => strategy_reason_counts(reasons),
         "gated_out_count" => diagnostics |> Map.get("gated_out", []) |> length(),
         "capped_out_count" => diagnostics |> Map.get("capped_out", []) |> length()
       }}
    end)
  end

  defp failure_rollups(strategy_trace) do
    strategy_trace
    |> Enum.reduce(
      %{
        "outcomes" => %{},
        "mode_counts" => %{},
        "mode_counts_by_outcome" => %{},
        "state_reason_counts" => %{},
        "underlying_reason_counts" => %{},
        "state_reason_counts_by_outcome" => %{},
        "underlying_reason_counts_by_outcome" => %{},
        "strategy_names_by_outcome" => %{},
        "strategy_names_by_mode" => %{}
      },
      fn {name, trace}, acc ->
        diagnostics = Map.get(trace, "diagnostics", %{})
        mode = strategy_mode(trace)
        outcome = strategy_outcome(trace)
        state_reason = strategy_state_reason(name, outcome)
        underlying_reasons = strategy_underlying_reasons(outcome, diagnostics, trace)

        acc
        |> update_in(["outcomes", outcome], fn value -> (value || 0) + 1 end)
        |> maybe_increment_mode_count(mode)
        |> maybe_increment_mode_count_by_outcome(outcome, mode)
        |> merge_count_map("state_reason_counts", strategy_reason_counts([state_reason]))
        |> merge_count_map("underlying_reason_counts", strategy_reason_counts(underlying_reasons))
        |> merge_nested_count_map(
          "state_reason_counts_by_outcome",
          outcome,
          strategy_reason_counts([state_reason])
        )
        |> merge_nested_count_map(
          "underlying_reason_counts_by_outcome",
          outcome,
          strategy_reason_counts(underlying_reasons)
        )
        |> update_in(["strategy_names_by_outcome", outcome], fn names ->
          ([name] ++ (names || []))
          |> Enum.uniq()
          |> Enum.sort()
        end)
        |> maybe_add_strategy_name_by_mode(mode, name)
      end
    )
    |> then(fn rollups ->
      rollups
      |> Map.put("ordered_outcomes", ordered_failure_outcomes(rollups))
      |> Map.put("ordered_modes", ordered_reason_counts(rollups["mode_counts"]))
      |> Map.put("ordered_state_reasons", ordered_reason_counts(rollups["state_reason_counts"]))
      |> Map.put(
        "ordered_underlying_reasons",
        ordered_reason_counts(rollups["underlying_reason_counts"])
      )
      |> Map.put("failure_overview", failure_overview(rollups))
    end)
  end

  defp strategy_outcomes(strategy_trace) do
    Map.new(strategy_trace, fn {name, trace} ->
      diagnostics = Map.get(trace, "diagnostics", %{})
      mode = strategy_mode(trace)
      active = Map.get(trace, "active", false)
      count = Map.get(trace, "count", 0)
      outcome = strategy_outcome(trace)
      pre_filter_count = Map.get(trace, "pre_filter_count", count)
      filtered_out_count = Map.get(trace, "filtered_out_count", 0)
      filtered_out_reason_counts = Map.get(trace, "filtered_out_reason_counts", %{})
      state_reason = strategy_state_reason(name, outcome)
      underlying_reasons = strategy_underlying_reasons(outcome, diagnostics, trace)
      state_reason_counts = strategy_reason_counts([state_reason])
      underlying_reason_counts = strategy_reason_counts(underlying_reasons)

      reasons = strategy_outcome_reasons(name, outcome, diagnostics, trace)

      {name,
       %{
         "mode" => mode,
         "outcome" => outcome,
         "reasons" => reasons,
         "state_reason" => state_reason,
         "underlying_reasons" => underlying_reasons,
         "state_reason_counts" => state_reason_counts,
         "underlying_reason_counts" => underlying_reason_counts,
         "active" => active,
         "count" => count,
         "pre_filter_count" => pre_filter_count,
         "filtered_out_count" => filtered_out_count,
         "filtered_out_reason_counts" => filtered_out_reason_counts,
         "gated_out_count" => diagnostics |> Map.get("gated_out", []) |> length(),
         "capped_out_count" => diagnostics |> Map.get("capped_out", []) |> length()
       }}
    end)
  end

  defp strategy_mode(trace), do: Map.get(trace, "mode")

  defp maybe_increment_mode_count(acc, nil), do: acc

  defp maybe_increment_mode_count(acc, mode) do
    update_in(acc, ["mode_counts", mode], fn value -> (value || 0) + 1 end)
  end

  defp maybe_increment_mode_count_by_outcome(acc, _outcome, nil), do: acc

  defp maybe_increment_mode_count_by_outcome(acc, outcome, mode) do
    update_in(acc, ["mode_counts_by_outcome", outcome], fn counts ->
      Map.update(counts || %{}, mode, 1, &(&1 + 1))
    end)
  end

  defp maybe_add_strategy_name_by_mode(acc, nil, _name), do: acc

  defp maybe_add_strategy_name_by_mode(acc, mode, name) do
    update_in(acc, ["strategy_names_by_mode", mode], fn names ->
      ([name] ++ (names || []))
      |> Enum.uniq()
      |> Enum.sort()
    end)
  end

  defp strategy_outcome(trace) do
    active = Map.get(trace, "active", false)
    count = Map.get(trace, "count", 0)
    pre_filter_count = Map.get(trace, "pre_filter_count", count)
    diagnostics = Map.get(trace, "diagnostics", %{})
    gated_out = Map.get(diagnostics, "gated_out", [])

    cond do
      not active -> "inactive"
      count == 0 and pre_filter_count > 0 -> "filtered_out"
      count == 0 and pre_filter_count == 0 and gated_out != [] -> "fully_gated"
      count == 0 -> "active_but_empty"
      true -> "contributed"
    end
  end

  defp strategy_outcome_reasons(name, outcome, diagnostics, trace) do
    state_reason = strategy_state_reason(name, outcome)
    underlying_reasons = strategy_underlying_reasons(outcome, diagnostics, trace)

    ([state_reason] ++ underlying_reasons)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp strategy_state_reason("temporal", "inactive"), do: "no_temporal_constraint"
  defp strategy_state_reason(_name, "inactive"), do: "not_applicable"
  defp strategy_state_reason(_name, "filtered_out"), do: "filtered_after_strategy_match"
  defp strategy_state_reason(_name, "fully_gated"), do: "all_candidates_gated_out"
  defp strategy_state_reason(_name, "active_but_empty"), do: "no_matches_after_strategy"
  defp strategy_state_reason(_name, "contributed"), do: nil

  defp strategy_underlying_reasons(outcome, diagnostics, trace) do
    diagnostic_reasons =
      diagnostics
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&Map.get(&1, "reason"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    filter_reasons =
      trace
      |> Map.get("filtered_out_reason_counts", %{})
      |> Map.keys()
      |> Enum.sort()

    case outcome do
      "filtered_out" ->
        filter_reasons

      "fully_gated" ->
        diagnostic_reasons
        |> Enum.reject(&(&1 == "all_candidates_gated_out"))

      "inactive" ->
        diagnostic_reasons
        |> Enum.reject(&(&1 in ["no_temporal_constraint", "not_applicable"]))

      "active_but_empty" ->
        []

      _ ->
        diagnostic_reasons
    end
  end

  defp strategy_reason_counts(reasons) do
    reasons
    |> Enum.frequencies()
  end

  defp merge_count_map(summary, key, additions) do
    update_in(summary, [key], fn counts ->
      Enum.reduce(additions, counts || %{}, fn {reason, count}, acc ->
        Map.update(acc, reason, count, &(&1 + count))
      end)
    end)
  end

  defp merge_nested_count_map(summary, key, outcome, additions) do
    update_in(summary, [key, outcome], fn counts ->
      Enum.reduce(additions, counts || %{}, fn {reason, count}, acc ->
        Map.update(acc, reason, count, &(&1 + count))
      end)
    end)
  end

  defp ordered_reason_counts(nil), do: []

  defp ordered_reason_counts(counts) do
    counts
    |> Enum.sort_by(fn {reason, count} -> {-count, reason} end)
    |> Enum.map(fn {reason, count} -> %{"reason" => reason, "count" => count} end)
  end

  defp ordered_failure_outcomes(rollups) do
    rollups
    |> Map.get("outcomes", %{})
    |> Enum.map(fn {outcome, count} ->
      %{
        "outcome" => outcome,
        "count" => count,
        "severity" => failure_outcome_severity(outcome),
        "dominant_state_reasons" =>
          rollups
          |> get_in(["state_reason_counts_by_outcome", outcome])
          |> ordered_reason_counts(),
        "dominant_underlying_reasons" =>
          rollups
          |> get_in(["underlying_reason_counts_by_outcome", outcome])
          |> ordered_reason_counts(),
        "dominant_modes" =>
          rollups
          |> get_in(["mode_counts_by_outcome", outcome])
          |> ordered_reason_counts(),
        "strategies" =>
          rollups
          |> get_in(["strategy_names_by_outcome", outcome])
          |> Kernel.||([])
      }
    end)
    |> Enum.sort_by(fn item ->
      {item["severity"], -item["count"], item["outcome"]}
    end)
  end

  defp failure_overview(rollups) do
    ordered_outcomes = ordered_failure_outcomes(rollups)
    ordered_modes = ordered_reason_counts(rollups["mode_counts"])
    ordered_state_reasons = ordered_reason_counts(rollups["state_reason_counts"])
    ordered_underlying_reasons = ordered_reason_counts(rollups["underlying_reason_counts"])
    top_outcome = List.first(ordered_outcomes)
    top_mode_bearing_outcome = top_mode_bearing_outcome(ordered_outcomes)

    %{
      "top_outcome" => top_outcome,
      "top_outcomes" => Enum.take(ordered_outcomes, 3),
      "top_mode" => List.first(ordered_modes),
      "top_modes" => Enum.take(ordered_modes, 3),
      "top_outcome_dominant_mode" => top_outcome && top_outcome["dominant_modes"] |> List.first(),
      "top_outcome_dominant_modes" =>
        if(top_outcome, do: Enum.take(top_outcome["dominant_modes"], 3), else: []),
      "top_mode_bearing_outcome" => top_mode_bearing_outcome,
      "top_mode_bearing_outcome_dominant_mode" =>
        top_mode_bearing_outcome && top_mode_bearing_outcome["dominant_modes"] |> List.first(),
      "top_mode_bearing_outcome_dominant_modes" =>
        if(top_mode_bearing_outcome,
          do: Enum.take(top_mode_bearing_outcome["dominant_modes"], 3),
          else: []
        ),
      "top_mode_bearing_outcome_dominant_state_reason" =>
        top_mode_bearing_outcome &&
          top_mode_bearing_outcome["dominant_state_reasons"] |> List.first(),
      "top_mode_bearing_outcome_dominant_state_reasons" =>
        if(top_mode_bearing_outcome,
          do: Enum.take(top_mode_bearing_outcome["dominant_state_reasons"], 3),
          else: []
        ),
      "top_mode_bearing_outcome_dominant_underlying_reason" =>
        top_mode_bearing_outcome &&
          top_mode_bearing_outcome["dominant_underlying_reasons"] |> List.first(),
      "top_mode_bearing_outcome_dominant_underlying_reasons" =>
        if(top_mode_bearing_outcome,
          do: Enum.take(top_mode_bearing_outcome["dominant_underlying_reasons"], 3),
          else: []
        ),
      "top_state_reason" => List.first(ordered_state_reasons),
      "top_state_reasons" => Enum.take(ordered_state_reasons, 3),
      "top_underlying_reason" => List.first(ordered_underlying_reasons),
      "top_underlying_reasons" => Enum.take(ordered_underlying_reasons, 3),
      "affected_strategy_count" =>
        rollups
        |> Map.get("strategy_names_by_outcome", %{})
        |> Map.values()
        |> List.flatten()
        |> Enum.uniq()
        |> length()
    }
  end

  defp top_mode_bearing_outcome(ordered_outcomes) do
    Enum.find(ordered_outcomes, fn outcome ->
      outcome["outcome"] != "inactive" and List.wrap(outcome["dominant_modes"]) != []
    end)
  end

  defp failure_outcome_severity("fully_gated"), do: 1
  defp failure_outcome_severity("filtered_out"), do: 2
  defp failure_outcome_severity("inactive"), do: 3
  defp failure_outcome_severity("active_but_empty"), do: 4
  defp failure_outcome_severity("contributed"), do: 5

  defp fusion_stage_rollups(
         fused_items,
         rerank_candidates,
         reranked_units,
         boosted_units,
         final_units
       ) do
    %{
      "rrf" => fusion_stage_rollup(fused_items),
      "rerank_candidates" => fusion_stage_rollup(rerank_candidates),
      "reranked" => fusion_stage_rollup(reranked_units),
      "boosted" => fusion_stage_rollup(boosted_units),
      "final" => fusion_stage_rollup(final_units)
    }
  end

  defp fusion_stage_rollup(items) do
    %{
      "count" => length(items),
      "single_strategy" =>
        Enum.count(items, &(map_size(Map.get(&1, "strategy_contributions", %{})) == 1)),
      "multi_strategy" =>
        Enum.count(items, &(map_size(Map.get(&1, "strategy_contributions", %{})) > 1)),
      "winning_strategies" => strategy_win_counts(items),
      "source_expansion_count" => Enum.count(items, &source_expansion_item?/1),
      "source_novel_only_count" => Enum.count(items, &source_novel_only_item?/1),
      "source_expansion_boosted_count" =>
        Enum.count(items, fn item ->
          (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_novel_only_boosted_count" =>
        Enum.count(items, fn item ->
          (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end)
    }
  end

  defp evidence_rollups(items) do
    %{
      "graph_hops" => hop_rollup(items, "graph_hop"),
      "temporal_hops" => hop_rollup(items, "temporal_hop"),
      "source_support" => %{
        "with_source_facts" =>
          Enum.count(items, fn item ->
            item |> Map.get("source_fact_ids", []) |> List.wrap() |> Enum.any?()
          end),
        "without_source_facts" =>
          Enum.count(items, fn item ->
            item |> Map.get("source_fact_ids", []) |> List.wrap() |> Enum.empty?()
          end),
        "avg_proof_count" => average_proof_count(items)
      }
    }
  end

  defp final_attribution(items) do
    %{
      "participating_strategies" => surviving_strategy_counts(items),
      "memory_breadth_boosted_survivors" => Enum.count(items, &memory_breadth_boosted_item?/1),
      "source_expansion_survivors" =>
        Enum.count(
          items,
          &Map.has_key?(Map.get(&1, "strategy_contributions", %{}), "source_expansion")
        ),
      "source_expansion_boosted_survivors" =>
        Enum.count(items, fn item ->
          Map.has_key?(Map.get(item, "strategy_contributions", %{}), "source_expansion") and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_novel_only_survivors" => Enum.count(items, &source_novel_only_item?/1),
      "source_novel_only_boosted_survivors" =>
        Enum.count(items, fn item ->
          source_novel_only_item?(item) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "exclusive_survivors" =>
        items
        |> Enum.filter(&(map_size(Map.get(&1, "strategy_contributions", %{})) == 1))
        |> surviving_strategy_counts(),
      "source_expansion_exclusive_survivors" =>
        items
        |> Enum.count(fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})
          map_size(contributions) == 1 and Map.has_key?(contributions, "source_expansion")
        end),
      "source_expansion_boosted_exclusive_survivors" =>
        items
        |> Enum.count(fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})

          map_size(contributions) == 1 and
            Map.has_key?(contributions, "source_expansion") and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_novel_only_exclusive_survivors" =>
        items
        |> Enum.count(fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})
          map_size(contributions) == 1 and source_novel_only_item?(item)
        end),
      "source_novel_only_boosted_exclusive_survivors" =>
        items
        |> Enum.count(fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})

          map_size(contributions) == 1 and
            source_novel_only_item?(item) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "multi_strategy_survivors" =>
        Enum.count(items, &(map_size(Map.get(&1, "strategy_contributions", %{})) > 1))
    }
  end

  defp strategy_evidence_attribution(items) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      item
      |> Map.get("strategy_contributions", %{})
      |> Map.keys()
      |> Enum.reduce(acc, fn strategy, inner_acc ->
        Map.update(inner_acc, strategy, strategy_evidence_seed(item, strategy), fn existing ->
          merge_strategy_evidence(existing, item, strategy)
        end)
      end)
    end)
    |> Map.new(fn {strategy, summary} ->
      {strategy, finalize_strategy_evidence(summary)}
    end)
  end

  defp surviving_strategy_counts(items) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      item
      |> Map.get("strategy_contributions", %{})
      |> Map.keys()
      |> Enum.reduce(acc, fn strategy, inner_acc ->
        Map.update(inner_acc, strategy, 1, &(&1 + 1))
      end)
    end)
  end

  defp strategy_evidence_seed(item, strategy) do
    source_expansion_contribution =
      if strategy == "source_expansion" do
        get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0
      else
        0.0
      end

    source_novel_only_contribution =
      if strategy == "source_expansion" and source_novel_only_item?(item) do
        get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0
      else
        0.0
      end

    %{
      "count" => 1,
      "graph_hops" => %{Integer.to_string(Map.get(item, "graph_hop", 0) || 0) => 1},
      "temporal_hops" => %{Integer.to_string(Map.get(item, "temporal_hop", 0) || 0) => 1},
      "with_source_facts" =>
        if(item |> Map.get("source_fact_ids", []) |> List.wrap() |> Enum.any?(), do: 1, else: 0),
      "without_source_facts" =>
        if(item |> Map.get("source_fact_ids", []) |> List.wrap() |> Enum.empty?(), do: 1, else: 0),
      "proof_total" => Map.get(item, "proof_count") || 1,
      "boosted_count" => if(source_expansion_contribution > 0.0, do: 1, else: 0),
      "boost_contribution_total" => source_expansion_contribution,
      "source_novel_only_count" => if(source_novel_only_item?(item), do: 1, else: 0),
      "source_novel_only_boosted_count" =>
        if(source_novel_only_contribution > 0.0, do: 1, else: 0),
      "source_novel_only_contribution_total" => source_novel_only_contribution
    }
  end

  defp merge_strategy_evidence(existing, item, strategy) do
    graph_hop = Integer.to_string(Map.get(item, "graph_hop", 0) || 0)
    temporal_hop = Integer.to_string(Map.get(item, "temporal_hop", 0) || 0)

    source_expansion_contribution =
      if strategy == "source_expansion" do
        get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0
      else
        0.0
      end

    source_novel_only_contribution =
      if strategy == "source_expansion" and source_novel_only_item?(item) do
        get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0
      else
        0.0
      end

    existing
    |> Map.update!("count", &(&1 + 1))
    |> update_in(["graph_hops", graph_hop], fn value -> (value || 0) + 1 end)
    |> update_in(["temporal_hops", temporal_hop], fn value -> (value || 0) + 1 end)
    |> Map.update!(
      "with_source_facts",
      &(&1 +
          if(item |> Map.get("source_fact_ids", []) |> List.wrap() |> Enum.any?(), do: 1, else: 0))
    )
    |> Map.update!(
      "without_source_facts",
      &(&1 +
          if(item |> Map.get("source_fact_ids", []) |> List.wrap() |> Enum.empty?(),
            do: 1,
            else: 0
          ))
    )
    |> Map.update!("proof_total", &(&1 + (Map.get(item, "proof_count") || 1)))
    |> Map.update!(
      "boosted_count",
      &(&1 + if(source_expansion_contribution > 0.0, do: 1, else: 0))
    )
    |> Map.update!("boost_contribution_total", &(&1 + source_expansion_contribution))
    |> Map.update!(
      "source_novel_only_count",
      &(&1 + if(source_novel_only_item?(item), do: 1, else: 0))
    )
    |> Map.update!(
      "source_novel_only_boosted_count",
      &(&1 + if(source_novel_only_contribution > 0.0, do: 1, else: 0))
    )
    |> Map.update!(
      "source_novel_only_contribution_total",
      &(&1 + source_novel_only_contribution)
    )
  end

  defp finalize_strategy_evidence(summary) do
    %{
      "count" => summary["count"],
      "graph_hops" => summary["graph_hops"],
      "temporal_hops" => summary["temporal_hops"],
      "with_source_facts" => summary["with_source_facts"],
      "without_source_facts" => summary["without_source_facts"],
      "avg_proof_count" => Float.round(summary["proof_total"] / max(summary["count"], 1), 3),
      "boosted_count" => summary["boosted_count"],
      "avg_boost_contribution" =>
        Float.round(summary["boost_contribution_total"] / max(summary["count"], 1), 6),
      "source_novel_only_count" => summary["source_novel_only_count"],
      "source_novel_only_boosted_count" => summary["source_novel_only_boosted_count"],
      "avg_source_novel_only_contribution" =>
        Float.round(summary["source_novel_only_contribution_total"] / max(summary["count"], 1), 6)
    }
  end

  defp stage_transitions(
         fused_items,
         rerank_candidates,
         reranked_units,
         boosted_units,
         final_units
       ) do
    %{
      "rrf_to_rerank_candidates" => stage_transition_rollup(fused_items, rerank_candidates),
      "rerank_candidates_to_reranked" =>
        stage_transition_rollup(rerank_candidates, reranked_units),
      "reranked_to_boosted" => stage_transition_rollup(reranked_units, boosted_units),
      "boosted_to_final" => stage_transition_rollup(boosted_units, final_units)
    }
  end

  defp stage_transition_rollup(from_items, to_items) do
    from_ids = MapSet.new(Enum.map(from_items, & &1["id"]))
    to_ids = MapSet.new(Enum.map(to_items, & &1["id"]))
    from_lookup = Map.new(from_items, &{&1["id"], &1})
    to_lookup = Map.new(to_items, &{&1["id"], &1})

    %{
      "from_count" => length(from_items),
      "to_count" => length(to_items),
      "retained" => Enum.count(from_ids, &MapSet.member?(to_ids, &1)),
      "dropped" => Enum.count(from_ids, &(not MapSet.member?(to_ids, &1))),
      "new" => Enum.count(to_ids, &(not MapSet.member?(from_ids, &1))),
      "memory_breadth_boosted_retained" =>
        Enum.count(from_ids, fn id ->
          MapSet.member?(to_ids, id) and memory_breadth_boosted_item?(Map.get(from_lookup, id))
        end),
      "memory_breadth_boosted_dropped" =>
        Enum.count(from_ids, fn id ->
          not MapSet.member?(to_ids, id) and
            memory_breadth_boosted_item?(Map.get(from_lookup, id))
        end),
      "memory_breadth_boosted_new" =>
        Enum.count(to_ids, fn id ->
          not MapSet.member?(from_ids, id) and
            memory_breadth_boosted_item?(Map.get(to_lookup, id))
        end),
      "source_expansion_retained" =>
        Enum.count(from_ids, fn id ->
          MapSet.member?(to_ids, id) and source_expansion_item?(Map.get(from_lookup, id))
        end),
      "source_novel_only_retained" =>
        Enum.count(from_ids, fn id ->
          MapSet.member?(to_ids, id) and source_novel_only_item?(Map.get(from_lookup, id))
        end),
      "source_expansion_boosted_retained" =>
        Enum.count(from_ids, fn id ->
          item = Map.get(from_lookup, id)

          MapSet.member?(to_ids, id) and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_novel_only_boosted_retained" =>
        Enum.count(from_ids, fn id ->
          item = Map.get(from_lookup, id)

          MapSet.member?(to_ids, id) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "source_expansion_dropped" =>
        Enum.count(from_ids, fn id ->
          not MapSet.member?(to_ids, id) and source_expansion_item?(Map.get(from_lookup, id))
        end),
      "source_novel_only_dropped" =>
        Enum.count(from_ids, fn id ->
          not MapSet.member?(to_ids, id) and source_novel_only_item?(Map.get(from_lookup, id))
        end),
      "source_expansion_boosted_dropped" =>
        Enum.count(from_ids, fn id ->
          item = Map.get(from_lookup, id)

          not MapSet.member?(to_ids, id) and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_novel_only_boosted_dropped" =>
        Enum.count(from_ids, fn id ->
          item = Map.get(from_lookup, id)

          not MapSet.member?(to_ids, id) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "source_expansion_new" =>
        Enum.count(to_ids, fn id ->
          not MapSet.member?(from_ids, id) and source_expansion_item?(Map.get(to_lookup, id))
        end),
      "source_novel_only_new" =>
        Enum.count(to_ids, fn id ->
          not MapSet.member?(from_ids, id) and source_novel_only_item?(Map.get(to_lookup, id))
        end),
      "source_expansion_boosted_new" =>
        Enum.count(to_ids, fn id ->
          item = Map.get(to_lookup, id)

          not MapSet.member?(from_ids, id) and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_novel_only_boosted_new" =>
        Enum.count(to_ids, fn id ->
          item = Map.get(to_lookup, id)

          not MapSet.member?(from_ids, id) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end)
    }
  end

  defp source_expansion_item?(nil), do: false

  defp source_expansion_item?(item) do
    Map.has_key?(Map.get(item, "strategy_contributions", %{}), "source_expansion")
  end

  defp source_novel_only_item?(nil), do: false

  defp source_novel_only_item?(item) do
    source_expansion_item?(item) and
      Map.get(item, "graph_source_shortfall_type") == "source_provenance" and
      Map.get(item, "graph_source_frontier_priority") == "novel_source_cluster"
  end

  defp source_frontier_breadth_item?(nil), do: false

  defp source_frontier_breadth_item?(item) do
    source_expansion_item?(item) and inferred_source_frontier_bonus(item) > 0.0
  end

  defp memory_breadth_boosted_item?(nil), do: false

  defp memory_breadth_boosted_item?(item) do
    case get_in(item, ["boosts", "memory_breadth_contribution"]) do
      value when is_number(value) and value > 0.0 -> true
      _ -> false
    end
  end

  defp hop_rollup(items, field) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      hop = Map.get(item, field, 0) || 0
      Map.update(acc, Integer.to_string(hop), 1, &(&1 + 1))
    end)
  end

  defp average_proof_count([]), do: 0.0

  defp average_proof_count(items) do
    items
    |> Enum.map(&(Map.get(&1, "proof_count") || 1))
    |> then(fn counts -> Enum.sum(counts) / max(length(counts), 1) end)
    |> Float.round(3)
  end

  defp winning_strategy(strategy_contributions) when strategy_contributions == %{}, do: nil

  defp winning_strategy(strategy_contributions) do
    strategy_contributions
    |> Enum.max_by(fn {strategy, score} -> {score, strategy} end)
    |> elem(0)
  end

  defp top_contribution(strategy_contributions) when strategy_contributions == %{}, do: 0.0

  defp top_contribution(strategy_contributions) do
    strategy_contributions
    |> Map.values()
    |> Enum.max(fn -> 0.0 end)
  end

  defp recall_visit_evidence(item) do
    %{
      "graph" => %{
        "hop" => Map.get(item, "graph_hop"),
        "seed_overlap_count" => Map.get(item, "graph_seed_overlap_count")
      },
      "temporal" => %{
        "hop" => Map.get(item, "temporal_hop"),
        "source_overlap_count" => item |> Map.get("temporal_source_overlap", []) |> length(),
        "seed_score" => Map.get(item, "temporal_seed_score"),
        "semantic_score" => Map.get(item, "temporal_semantic_score")
      }
    }
  end

  defp recall_summary(
         payload,
         strategy_trace,
         fused_items,
         rerank_candidates,
         reranked_units,
         boosted_units,
         final_units
       ) do
    failure_rollups = failure_rollups(strategy_trace)

    source_expansion =
      source_expansion_summary(
        payload,
        strategy_trace,
        fused_items,
        rerank_candidates,
        boosted_units,
        final_units
      )

    %{
      "budget" => Map.get(payload, "budget", "mid"),
      "recall_budget" => recall_budget(payload),
      "max_tokens" => Map.get(payload, "max_tokens", 4096),
      "semantic_similarity_floor" => @semantic_similarity_floor,
      "semantic_fetch_limit" => semantic_fetch_limit(payload),
      "active_strategies" =>
        strategy_trace
        |> Enum.filter(fn {_name, trace} -> trace["active"] end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort(),
      "strategy_outcomes" => strategy_outcomes(strategy_trace),
      "strategy_rollups" => strategy_rollups(strategy_trace),
      "failure_rollups" => enrich_failure_rollups(failure_rollups, source_expansion),
      "fusion_stage_rollups" =>
        fusion_stage_rollups(
          fused_items,
          rerank_candidates,
          reranked_units,
          boosted_units,
          final_units
        ),
      "source_expansion" => source_expansion,
      "memory_breadth" =>
        memory_breadth_summary(
          payload,
          fused_items,
          rerank_candidates,
          boosted_units,
          final_units
        ),
      "evidence_rollups" => evidence_rollups(final_units),
      "final_attribution" => final_attribution(final_units),
      "strategy_evidence_attribution" => strategy_evidence_attribution(final_units),
      "stage_transitions" =>
        stage_transitions(
          fused_items,
          rerank_candidates,
          reranked_units,
          boosted_units,
          final_units
        ),
      "fusion_overlap" => %{
        "single_strategy_candidates" =>
          Enum.count(fused_items, &(map_size(Map.get(&1, "strategy_contributions", %{})) == 1)),
        "multi_strategy_candidates" =>
          Enum.count(fused_items, &(map_size(Map.get(&1, "strategy_contributions", %{})) > 1))
      },
      "rerank_window" => rerank_window_summary(fused_items, rerank_candidates),
      "strategy_wins" => strategy_win_counts(final_units),
      "candidate_count" => length(fused_items),
      "rerank_candidate_count" => length(rerank_candidates),
      "reranked_count" => length(reranked_units),
      "boosted_count" => length(boosted_units),
      "final_count" => length(final_units)
    }
  end

  defp enrich_failure_rollups(rollups, source_expansion) do
    ordered_source_frontier_breadth =
      source_expansion
      |> source_frontier_breadth_counts()
      |> ordered_reason_counts()

    ordered_source_novel_only =
      source_expansion
      |> source_novel_only_counts()
      |> ordered_reason_counts()

    rollups
    |> Map.put("source_frontier_breadth_counts", source_frontier_breadth_counts(source_expansion))
    |> Map.put("ordered_source_frontier_breadth", ordered_source_frontier_breadth)
    |> Map.put("source_novel_only_counts", source_novel_only_counts(source_expansion))
    |> Map.put("ordered_source_novel_only", ordered_source_novel_only)
    |> update_in(["failure_overview"], fn overview ->
      overview
      |> Map.put("top_source_frontier_breadth", List.first(ordered_source_frontier_breadth))
      |> Map.put("top_source_frontier_breadths", Enum.take(ordered_source_frontier_breadth, 3))
      |> Map.put("top_source_novel_only", List.first(ordered_source_novel_only))
      |> Map.put("top_source_novel_only_reasons", Enum.take(ordered_source_novel_only, 3))
    end)
  end

  defp source_frontier_breadth_counts(source_expansion) do
    %{
      "survivor" => source_expansion["frontier_breadth_survivor_count"] || 0,
      "windowed_out" => source_expansion["frontier_breadth_windowed_out_count"] || 0,
      "trimmed_out" => source_expansion["frontier_breadth_trimmed_out_count"] || 0
    }
    |> Enum.reject(fn {_key, value} -> value <= 0 end)
    |> Map.new()
  end

  defp source_novel_only_counts(source_expansion) do
    %{
      "filtered" => source_expansion["novel_only_filtered_count"] || 0
    }
    |> Enum.reject(fn {_key, value} -> value <= 0 end)
    |> Map.new()
  end

  defp source_expansion_summary(
         payload,
         strategy_trace,
         fused_items,
         rerank_candidates,
         boosted_units,
         final_units
       ) do
    final_ids = MapSet.new(Enum.map(final_units, & &1["id"]))
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))

    %{
      "active" => source_expansion_mode?(payload),
      "fused_count" => Enum.count(fused_items, &Map.get(&1, "graph_source_expansion", false)),
      "final_count" => Enum.count(final_units, &Map.get(&1, "graph_source_expansion", false)),
      "frontier" => source_expansion_frontier_summary(fused_items),
      "survivor_count" =>
        Enum.count(
          final_units,
          &Map.has_key?(Map.get(&1, "strategy_contributions", %{}), "source_expansion")
        ),
      "frontier_breadth_survivor_count" =>
        Enum.count(final_units, &source_frontier_breadth_item?/1),
      "exclusive_survivor_count" =>
        Enum.count(final_units, fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})
          map_size(contributions) == 1 and Map.has_key?(contributions, "source_expansion")
        end),
      "boosted_retained_count" =>
        Enum.count(boosted_units, fn item ->
          MapSet.member?(final_ids, item["id"]) and
            Map.has_key?(Map.get(item, "strategy_contributions", %{}), "source_expansion")
        end),
      "boosted_dropped_count" =>
        Enum.count(boosted_units, fn item ->
          not MapSet.member?(final_ids, item["id"]) and
            Map.has_key?(Map.get(item, "strategy_contributions", %{}), "source_expansion")
        end),
      "windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          source_expansion_item?(item) and not MapSet.member?(rerank_candidate_ids, item["id"])
        end),
      "frontier_breadth_windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          source_frontier_breadth_item?(item) and
            not MapSet.member?(rerank_candidate_ids, item["id"])
        end),
      "boosted_windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          not MapSet.member?(rerank_candidate_ids, item["id"]) and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "boosted_trimmed_out_count" =>
        Enum.count(boosted_units, fn item ->
          not MapSet.member?(final_ids, item["id"]) and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "frontier_breadth_trimmed_out_count" =>
        Enum.count(boosted_units, fn item ->
          not MapSet.member?(final_ids, item["id"]) and source_frontier_breadth_item?(item)
        end),
      "novel_only_filtered_count" => source_novel_only_filtered_count(strategy_trace),
      "novel_only_survivor_count" => Enum.count(final_units, &source_novel_only_item?/1),
      "novel_only_boosted_survivor_count" =>
        Enum.count(final_units, fn item ->
          source_novel_only_item?(item) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "novel_only_exclusive_survivor_count" =>
        Enum.count(final_units, fn item ->
          map_size(Map.get(item, "strategy_contributions", %{})) == 1 and
            source_novel_only_item?(item)
        end),
      "novel_only_boosted_exclusive_survivor_count" =>
        Enum.count(final_units, fn item ->
          map_size(Map.get(item, "strategy_contributions", %{})) == 1 and
            source_novel_only_item?(item) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "novel_only_windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          source_novel_only_item?(item) and not MapSet.member?(rerank_candidate_ids, item["id"])
        end),
      "novel_only_boosted_windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          not MapSet.member?(rerank_candidate_ids, item["id"]) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "novel_only_boosted_trimmed_out_count" =>
        Enum.count(boosted_units, fn item ->
          not MapSet.member?(final_ids, item["id"]) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end)
    }
  end

  defp source_expansion_frontier_summary(fused_items) do
    source_items = Enum.filter(fused_items, &source_expansion_item?/1)

    %{
      "priority_counts" =>
        source_items
        |> Enum.map(&Map.get(&1, "graph_source_frontier_priority"))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies(),
      "shortfall_type_counts" =>
        source_items
        |> Enum.map(&Map.get(&1, "graph_source_shortfall_type"))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies(),
      "novel_group_count" =>
        source_items
        |> Enum.filter(&(Map.get(&1, "graph_source_frontier_novel_count", 0) > 0))
        |> Enum.map(&Map.get(&1, "graph_source_frontier_group"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length()
    }
  end

  defp memory_breadth_summary(payload, fused_items, rerank_candidates, boosted_units, final_units) do
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))
    final_ids = MapSet.new(Enum.map(final_units, & &1["id"]))

    %{
      "active" => memory_breadth_mode?(payload),
      "boosted_count" => Enum.count(boosted_units, &memory_breadth_boosted_item?/1),
      "survivor_count" => Enum.count(final_units, &memory_breadth_boosted_item?/1),
      "windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          not MapSet.member?(rerank_candidate_ids, item["id"]) and
            memory_breadth_boosted_item?(item)
        end),
      "trimmed_out_count" =>
        Enum.count(boosted_units, fn item ->
          not MapSet.member?(final_ids, item["id"]) and memory_breadth_boosted_item?(item)
        end)
    }
  end

  defp maybe_add_source_expansion_fusion_strategy(strategy_items) do
    source_expansion_items =
      strategy_items
      |> Map.get("graph", [])
      |> Enum.filter(&Map.get(&1, "graph_source_expansion", false))
      |> Enum.map(fn item ->
        frontier_bonus = source_expansion_frontier_bonus(item)

        item
        |> Map.put("graph_source_frontier_bonus", frontier_bonus)
        |> Map.put(
          "source_expansion_score",
          Float.round(Map.get(item, "graph_source_traversal_score", 0.0) + frontier_bonus, 6)
        )
      end)

    case source_expansion_items do
      [] -> strategy_items
      _ -> Map.put(strategy_items, "source_expansion", source_expansion_items)
    end
  end

  defp source_expansion_frontier_bonus(item) do
    shortfall_type = Map.get(item, "graph_source_shortfall_type")
    priority = Map.get(item, "graph_source_frontier_priority")
    novel_count = Map.get(item, "graph_source_frontier_novel_count", 0)

    base_bonus =
      case {shortfall_type, priority} do
        {"source_family", "novel_document_family"} -> 0.25
        {"raw_memory_breadth", "novel_memory_family"} -> 0.3
        {"source_lineage", "extends_source_lineage"} -> 0.35
        {"source_lineage", "novel_source_cluster"} -> 0.2
        {"source_provenance", "novel_source_cluster"} -> 0.25
        _ -> 0.0
      end

    novelty_bonus = min(max(novel_count, 0), 3) * 0.05
    Float.round(base_bonus + novelty_bonus, 6)
  end

  defp recall_pruned(
         fused_items,
         rerank_candidates,
         reranked_units,
         boosted_units,
         final_units
       ) do
    final_ids = MapSet.new(Enum.map(final_units, & &1["id"]))
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))
    final_count = length(final_units)
    rerank_cutoff_score = rerank_cutoff_score(rerank_candidates)

    %{
      "before_rerank" => length(fused_items),
      "rerank_candidates" => length(rerank_candidates),
      "after_rerank" => length(reranked_units),
      "after_boost" => length(boosted_units),
      "after_trim" => final_count,
      "dropped_before_rerank_ids" =>
        fused_items
        |> Enum.reject(&MapSet.member?(rerank_candidate_ids, &1["id"]))
        |> Enum.map(& &1["id"]),
      "dropped_before_rerank" =>
        fused_items
        |> Enum.with_index(1)
        |> Enum.reject(fn {item, _rank} -> MapSet.member?(rerank_candidate_ids, item["id"]) end)
        |> Enum.map(fn {item, rank} ->
          strategy_contributions = Map.get(item, "strategy_contributions", %{})

          %{
            "node_id" => item["id"],
            "text" => item["content"],
            "rank" => rank,
            "score" => Map.get(item, "rrf_score", 0.0),
            "winning_strategy" => winning_strategy(strategy_contributions),
            "strategy_count" => map_size(strategy_contributions),
            "top_contribution" => top_contribution(strategy_contributions),
            "source_expansion" => Map.has_key?(strategy_contributions, "source_expansion"),
            "source_expansion_score" =>
              get_in(item, ["strategy_contribution_details", "source_expansion", "native_score"]) ||
                0.0,
            "source_novel_only" => source_novel_only_item?(item),
            "cutoff_score" => rerank_cutoff_score,
            "margin_to_cutoff" =>
              cutoff_margin(rerank_cutoff_score, Map.get(item, "rrf_score", 0.0)),
            "explanations" => rerank_window_loss_explanations(item, strategy_contributions),
            "reason" => "rerank_candidate_cap"
          }
        end),
      "dropped_ids" =>
        boosted_units
        |> Enum.reject(&MapSet.member?(final_ids, &1["id"]))
        |> Enum.map(& &1["id"]),
      "dropped_after_trim" =>
        boosted_units
        |> Enum.with_index(1)
        |> Enum.reject(fn {item, _rank} -> MapSet.member?(final_ids, item["id"]) end)
        |> Enum.map(fn {item, rank} ->
          strategy_contributions = Map.get(item, "strategy_contributions", %{})

          %{
            "node_id" => item["id"],
            "text" => item["content"],
            "rank" => rank,
            "score" => Map.get(item, "boosted_score", 0.0),
            "tokens" => recall_item_token_count_value(item),
            "kept_slots" => final_count,
            "winning_strategy" => winning_strategy(strategy_contributions),
            "strategy_count" => map_size(strategy_contributions),
            "top_contribution" => top_contribution(strategy_contributions),
            "source_expansion" => Map.has_key?(strategy_contributions, "source_expansion"),
            "source_expansion_contribution" =>
              get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0,
            "source_expansion_boost" => get_in(item, ["boosts", "source_expansion_boost"]) || 1.0,
            "source_novel_only" => source_novel_only_item?(item),
            "explanations" => trim_loss_explanations(item, strategy_contributions),
            "reason" => "max_tokens_trim"
          }
        end),
      "trim_rollups" => trim_rollups(boosted_units, final_ids)
    }
  end

  defp rerank_window_loss_explanations(item, strategy_contributions) do
    []
    |> maybe_add_overlap_explanation(%{"strategy_contributions" => strategy_contributions})
    |> maybe_add_source_expansion_explanation(item, "source_expansion_missed_rerank_window")
    |> maybe_add_source_novel_only_explanation(item, "source_novel_only_missed_rerank_window")
    |> Enum.reverse()
  end

  defp trim_loss_explanations(item, strategy_contributions) do
    []
    |> maybe_add_overlap_explanation(%{"strategy_contributions" => strategy_contributions})
    |> maybe_add_source_expansion_explanation(item, "source_expansion_trimmed")
    |> maybe_add_source_novel_only_explanation(item, "source_novel_only_trimmed")
    |> Enum.reverse()
  end

  defp trim_rollups(boosted_units, final_ids) do
    trimmed_items =
      boosted_units
      |> Enum.reject(&MapSet.member?(final_ids, &1["id"]))

    %{
      "count" => length(trimmed_items),
      "source_expansion_count" =>
        Enum.count(
          trimmed_items,
          &Map.has_key?(Map.get(&1, "strategy_contributions", %{}), "source_expansion")
        ),
      "source_expansion_boosted_count" =>
        Enum.count(trimmed_items, fn item ->
          (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "source_expansion_boosted_winning_strategies" =>
        trimmed_items
        |> Enum.filter(fn item ->
          (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end)
        |> strategy_win_counts(),
      "winning_strategies" => strategy_win_counts(trimmed_items)
    }
  end

  defp strategy_win_counts(items) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      case winning_strategy(Map.get(item, "strategy_contributions", %{})) do
        nil -> acc
        strategy -> Map.update(acc, strategy, 1, &(&1 + 1))
      end
    end)
  end

  defp rerank_window_summary(fused_items, rerank_candidates) do
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))

    %{
      "cutoff_rank" => if(rerank_candidates == [], do: nil, else: length(rerank_candidates)),
      "cutoff_score" => rerank_cutoff_score(rerank_candidates),
      "single_strategy_candidates" =>
        Enum.count(
          rerank_candidates,
          &(map_size(Map.get(&1, "strategy_contributions", %{})) == 1)
        ),
      "multi_strategy_candidates" =>
        Enum.count(rerank_candidates, &(map_size(Map.get(&1, "strategy_contributions", %{})) > 1)),
      "strategy_wins" => strategy_win_counts(rerank_candidates),
      "source_expansion_candidates" => Enum.count(rerank_candidates, &source_expansion_item?(&1)),
      "source_expansion_exclusive_candidates" =>
        Enum.count(rerank_candidates, fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})
          map_size(contributions) == 1 and Map.has_key?(contributions, "source_expansion")
        end),
      "source_expansion_windowed_out" =>
        Enum.count(fused_items, fn item ->
          source_expansion_item?(item) and not MapSet.member?(rerank_candidate_ids, item["id"])
        end),
      "source_expansion_exclusive_windowed_out" =>
        Enum.count(fused_items, fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})

          map_size(contributions) == 1 and
            Map.has_key?(contributions, "source_expansion") and
            not MapSet.member?(rerank_candidate_ids, item["id"])
        end)
    }
  end

  defp rerank_cutoff_score([]), do: nil

  defp rerank_cutoff_score(rerank_candidates),
    do: rerank_candidates |> List.last() |> Map.get("rrf_score")

  defp cutoff_margin(nil, _score), do: nil
  defp cutoff_margin(cutoff_score, score), do: Float.round(cutoff_score - score, 12)

  defp prefilter_rerank_candidates(candidates, payload) do
    candidates
    |> Enum.sort_by(fn item ->
      {-source_novel_only_priority(item, payload), -Map.get(item, "rrf_score", 0.0), item["id"]}
    end)
    |> Enum.take(300)
  end

  defp recall_item_token_count_value(item) do
    case item |> Map.get("content", Map.get(item, "text", "")) |> Budget.count_tokens() do
      {:ok, count} -> count
      _ -> nil
    end
  end

  defp recall_budget(%{"budget" => "low"}), do: 100
  defp recall_budget(%{"budget" => "high"}), do: 1000
  defp recall_budget(_payload), do: 300

  defp semantic_candidate_limit(payload), do: recall_budget(payload)

  defp semantic_fetch_limit(payload) do
    max(
      semantic_candidate_limit(payload) * @semantic_overfetch_multiplier,
      @semantic_overfetch_min
    )
  end

  defp temporal_entry_point_limit(payload),
    do: min(@temporal_entry_point_limit, recall_budget(payload))

  defp temporal_result_limit(payload), do: min(@temporal_result_limit, recall_budget(payload))

  defp boost_recall_items(items, payload) do
    memory_family_counts = recall_memory_family_counts(items, payload)

    items
    |> Enum.map(&apply_recall_boosts(&1, payload, memory_family_counts))
    |> Enum.sort_by(fn item ->
      {-source_novel_only_priority(item, payload), -Map.get(item, "boosted_score", 0.0),
       -Map.get(item, "rerank_score", 0.0), -Map.get(item, "rrf_score", 0.0), item["id"]}
    end)
  end

  defp source_novel_only_priority(item, payload) do
    if source_expansion_novel_only?(payload) and source_novel_only_item?(item), do: 1, else: 0
  end

  # Mirror of Foresight.Storage.Ecto.apply_recall_boosts/3 after the corpus-string decontamination:
  # no corpus-string factors, generic status prior at α=0.2, and a clamped multiplier so
  # the reranker stays authoritative. Kept in sync so the fake exercises honest ranking.
  defp apply_recall_boosts(item, payload, memory_family_counts) do
    recency = recall_recency_factor(item, payload)
    temporal = recall_temporal_factor(item, payload)
    proof = recall_proof_factor(item)
    source_expansion = recall_source_expansion_factor(item)
    source_novel_only = recall_source_novel_only_factor(item, payload)
    revision_status = recall_revision_status_factor(item)
    memory_breadth = recall_memory_breadth_factor(item, payload, memory_family_counts)

    recency_contribution = 0.2 * (recency - 0.5)
    temporal_contribution = 0.2 * (temporal - 0.5)
    proof_contribution = 0.1 * (proof - 0.5)
    source_expansion_contribution = 0.15 * (source_expansion - 0.5)
    source_novel_only_contribution = 0.1 * (source_novel_only - 0.5)
    revision_status_contribution = 0.2 * (revision_status - 0.5)
    memory_breadth_contribution = 0.15 * (memory_breadth - 0.5)

    recency_boost = 1.0 + recency_contribution
    temporal_boost = 1.0 + temporal_contribution
    proof_boost = 1.0 + proof_contribution
    source_expansion_boost = 1.0 + source_expansion_contribution
    source_novel_only_boost = 1.0 + source_novel_only_contribution
    revision_status_boost = 1.0 + revision_status_contribution
    memory_breadth_boost = 1.0 + memory_breadth_contribution

    boost_multiplier =
      recency_boost * temporal_boost * proof_boost * source_expansion_boost *
        source_novel_only_boost * revision_status_boost * memory_breadth_boost

    clamped_multiplier = clamp_recall_boost_multiplier(boost_multiplier)

    boosted_score =
      item
      |> Map.get("rerank_score", 0.0)
      |> apply_recall_boost_multiplier(clamped_multiplier)

    item
    |> Map.put("boosted_score", Float.round(boosted_score, 6))
    |> Map.put("score", Float.round(boosted_score, 6))
    |> Map.put("boosts", %{
      "recency" => Float.round(recency, 6),
      "recency_boost" => Float.round(recency_boost, 6),
      "recency_contribution" => Float.round(recency_contribution, 6),
      "temporal" => Float.round(temporal, 6),
      "temporal_boost" => Float.round(temporal_boost, 6),
      "temporal_contribution" => Float.round(temporal_contribution, 6),
      "proof" => Float.round(proof, 6),
      "proof_boost" => Float.round(proof_boost, 6),
      "proof_contribution" => Float.round(proof_contribution, 6),
      "source_expansion" => Float.round(source_expansion, 6),
      "source_expansion_boost" => Float.round(source_expansion_boost, 6),
      "source_expansion_contribution" => Float.round(source_expansion_contribution, 6),
      "source_novel_only" => Float.round(source_novel_only, 6),
      "source_novel_only_boost" => Float.round(source_novel_only_boost, 6),
      "source_novel_only_contribution" => Float.round(source_novel_only_contribution, 6),
      "revision_status" => Float.round(revision_status, 6),
      "revision_status_boost" => Float.round(revision_status_boost, 6),
      "revision_status_contribution" => Float.round(revision_status_contribution, 6),
      "memory_breadth" => Float.round(memory_breadth, 6),
      "memory_breadth_boost" => Float.round(memory_breadth_boost, 6),
      "memory_breadth_contribution" => Float.round(memory_breadth_contribution, 6),
      "memory_breadth_family" => recall_memory_family_key(item),
      "boost_multiplier" => Float.round(boost_multiplier, 6),
      "boost_multiplier_clamped" => Float.round(clamped_multiplier, 6)
    })
  end

  @recall_boost_min 0.75
  @recall_boost_max 1.25

  defp clamp_recall_boost_multiplier(multiplier) when is_number(multiplier) do
    multiplier |> max(@recall_boost_min) |> min(@recall_boost_max)
  end

  defp recall_memory_family_counts(items, payload) do
    if memory_breadth_mode?(payload) do
      items
      |> Enum.map(&recall_memory_family_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
    else
      %{}
    end
  end

  defp recall_memory_breadth_factor(item, payload, family_counts) do
    cond do
      not memory_breadth_mode?(payload) ->
        0.5

      is_nil(recall_memory_family_key(item)) ->
        0.5

      true ->
        family_count =
          item
          |> recall_memory_family_key()
          |> then(&Map.get(family_counts, &1, 1))

        Float.round(0.5 + 0.5 / max(family_count, 1), 6)
    end
  end

  defp recall_source_novel_only_factor(item, payload) do
    if source_expansion_novel_only?(payload) and source_novel_only_item?(item), do: 1.0, else: 0.5
  end

  defp recall_memory_family_key(%{"type" => "observation"}), do: nil

  defp recall_memory_family_key(item) do
    cond do
      is_binary(document_ref(item)) and document_ref(item) != "" ->
        "document_family:" <> document_ref(item)

      is_binary(Map.get(item, "id")) and Map.get(item, "id") != "" ->
        "memory:" <> Map.get(item, "id")

      true ->
        nil
    end
  end

  defp recall_recency_factor(item, payload) do
    case {recall_item_datetime(item), recall_anchor_datetime(payload)} do
      {%DateTime{} = memory_time, %DateTime{} = anchor_time} ->
        age_days = max(DateTime.diff(anchor_time, memory_time, :day), 0)
        max(0.1, 1.0 - age_days / 365.0)

      _ ->
        0.5
    end
  end

  defp recall_temporal_factor(item, payload) do
    case temporal_constraint(payload["query"], payload["query_timestamp"]) do
      nil -> 0.5
      constraint -> temporal_score(item, constraint, payload["query_timestamp"])
    end
  end

  defp recall_proof_factor(item) do
    proof_count =
      item["proof_count"] ||
        case Map.get(item, "source_fact_ids") do
          ids when is_list(ids) and ids != [] -> length(ids)
          _ -> 1
        end

    proof_norm = 0.5 + :math.log(max(proof_count, 1)) / 10
    max(0.0, min(1.0, proof_norm))
  end

  # Mirror of the decontaminated Ecto factor: a single generic status:* prior, no query
  # or content inspection, no intent classification.
  defp recall_revision_status_factor(item) do
    tags = Map.get(item, "tags", [])

    cond do
      "status:superseded" in tags -> 0.0
      "status:stale" in tags -> 0.0
      "status:corrected" in tags -> 1.0
      "status:latest" in tags -> 0.7
      "status:clarified" in tags -> 0.6
      true -> 0.5
    end
  end

  defp recall_source_expansion_factor(item) do
    if Map.has_key?(Map.get(item, "strategy_contributions", %{}), "source_expansion") do
      source_expansion_score =
        case Map.get(item, "source_expansion_score") do
          value when is_number(value) ->
            value

          _ ->
            get_in(item, ["strategy_contribution_details", "source_expansion", "native_score"]) ||
              0.0
        end

      source_expansion_score
      |> Kernel./(3.0)
      |> Kernel.+(0.5)
      |> max(0.5)
      |> min(1.0)
    else
      0.5
    end
  end

  defp recall_anchor_datetime(%{"query_timestamp" => value}) when is_binary(value) do
    parse_datetime(value) || DateTime.utc_now()
  end

  defp recall_anchor_datetime(_payload), do: DateTime.utc_now()

  defp recall_item_datetime(item) do
    parse_datetime(item["occurred_start"]) ||
      parse_datetime(item["occurred_end"]) ||
      parse_datetime(item["mentioned_at"])
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_source_memory_ids(%{"source_memory_ids" => ids}) when is_list(ids), do: ids
  defp normalize_source_memory_ids(%{"source_fact_ids" => ids}) when is_list(ids), do: ids
  defp normalize_source_memory_ids(_item), do: []

  defp strategy_score(item, "semantic"), do: Map.get(item, "semantic_score", 0.0)
  defp strategy_score(item, "keyword"), do: Map.get(item, "keyword_score", 0.0)
  defp strategy_score(item, "graph"), do: Map.get(item, "graph_score", 0.0)
  defp strategy_score(item, "temporal"), do: Map.get(item, "temporal_score", 0.0)
  defp strategy_score(_item, _name), do: 0.0
end
