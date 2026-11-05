defmodule Foresight.Storage.Ecto do
  @moduledoc false

  @behaviour Foresight.Storage

  import Ecto.Query
  import Pgvector.Ecto.Query

  alias Ecto.Multi
  alias Ecto.Adapters.SQL
  alias Foresight.Budget
  alias Foresight.Config.Guard
  alias Foresight.Config.Fields
  alias Foresight.Config.Resolver
  alias Foresight.Embeddings.Profile, as: EmbeddingProfile
  alias Foresight.Entities.Resolution
  alias Foresight.EntityExtractor
  alias Foresight.Error
  alias Foresight.Evals.Labeling.CandidatePool
  alias Foresight.Recall.SemanticFloor
  alias Foresight.Reflect.EntailmentGate
  alias Foresight.Reflect.EntailmentVerifiers.Noop, as: NoopVerifier
  alias Foresight.Schemas.AuditLog
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.Delivery
  alias Foresight.Schemas.Document
  alias Foresight.Schemas.Directive
  alias Foresight.Schemas.Entity
  alias Foresight.Schemas.EntityEmbedding
  alias Foresight.Schemas.EntityLink
  alias Foresight.Schemas.FileStorage
  alias Foresight.Schemas.MemoryLink
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Schemas.MemoryUnitEntity
  alias Foresight.Schemas.Webhook
  alias Foresight.Storage.Consolidation
  alias Foresight.Storage.ConsolidationPersistence
  alias Foresight.Storage.ConsolidationSupport
  alias Foresight.Storage.LinkConstruction
  alias Foresight.Webhooks

  @default_limit 100
  @default_offset 0
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
  # Mirrors Prompts.Reflect.Tools @default_observations_max_tokens (the tool
  # schema's advertised default); larger than recall's generic 4096 so the
  # observation tier surfaces more consolidated facts.
  @reflect_observation_max_tokens 5000
  # search_mental_models result cap ; mirrors Prompts.Reflect.Tools'
  # @default_mental_model_max_results so tool + storage agree on the default.
  @default_mental_model_search_limit 5
  # Evidence budget for the agentic reflect pre-seed + `recall` tool, matching the
  # recall tool schema's advertised default (and Hindsight's). The reflect payload's
  # `max_tokens` caps the ANSWER, and must NOT be conflated with the recall evidence
  # budget — doing so starved the pre-seed to a couple of facts and caused
  # multi-session under-counting.
  @reflect_recall_max_tokens 2048
  # Floor for an explicit recall-tool budget: a value below this is never an
  # intentional evidence budget (e.g. a stray `1` / `1.0`), so it falls through to
  # the default rather than collapsing recall to a token or two (audit NIT).
  @reflect_recall_min_tokens 256
  @leaked_json_suffix ~r/\s*```(?:json)?\s*\{[^}]*(?:"(?:observation_ids|memory_ids|mental_model_ids)"|\})\s*```\s*$/si
  @leaked_json_object ~r/\s*\{[^{]*"(?:observation_ids|memory_ids|mental_model_ids|answer)"[^}]*\}\s*$/s
  @trailing_ids_pattern ~r/\s*(?:observation_ids|memory_ids|mental_model_ids)\s*[=:]\s*\[.*?\]\s*$/si

  @impl true
  def retain(ctx, %{"async" => true} = payload, opts) do
    queue = Keyword.fetch!(opts, :queue)
    queue.enqueue_retain(ctx, payload, opts)
  end

  def retain(ctx, %{"items" => items} = payload, opts) when is_list(items) do
    case validate_retain_item_sizes(items) do
      :ok -> do_retain(ctx, payload, opts)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def retain(_ctx, _payload, _opts) do
    {:error, Error.new(:invalid_request, %{message: "retain payload must include an items list"})}
  end

  defp do_retain(ctx, %{"items" => items} = payload, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Every chargeable call from here on (extraction LLM, remote embeddings for the
    # units and entity names) is recorded and reported under "usage".
    Foresight.Usage.start()

    # Atomic-fact extraction runs BEFORE with_tenant_scope: it needs the
    # LLM only, no tenant DB access, so it must not hold a scoped connection during
    # the (potentially multi-second) extraction call. Gated off by default — a nil
    # mode is passthrough, preserving the historical one-item-per-input behaviour.
    {{extracted_items, extraction_stats}, extraction_ms} =
      timed_ms(fn ->
        items
        |> extract_retain_items()
        |> Foresight.Retain.FactExtraction.extract(retain_extraction_opts(opts))
      end)

    with_tenant_scope(ctx, repo, opts, fn ->
      embedder = Keyword.fetch!(opts, :embedder)
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()
      runtime_cfg = runtime_config(opts)

      {resolved_runtime_config, runtime_config_ms} =
        timed_ms(fn ->
          resolve_runtime_bank_config(repo, ctx, repo_opts, runtime_cfg).config
        end)

      with {{:ok, profile}, embedding_profile_ms} <-
             timed_ms(fn ->
               EmbeddingProfile.resolve(resolved_runtime_config,
                 embedder: embedder,
                 runtime_config: runtime_cfg
               )
             end),
           :ok <- ensure_nonempty_retain_extraction(extracted_items),
           {{:ok, prepared_memory_units}, prepare_memory_units_ms} <-
             timed_ms(fn ->
               prepare_memory_unit_attrs(ctx.bank, extracted_items, embedder, profile)
             end) do
        base_result = %{
          "success" => true,
          "bank_id" => ctx.bank,
          "items_count" => length(items),
          "async" => false,
          "usage" => nil,
          "extraction" => extraction_report(extraction_stats)
        }

        with {{:ok, %{memory_units: inserted, usage: usage}}, transaction_ms} <-
               timed_ms(fn ->
                 with_deadlock_retry(fn ->
                   Multi.new()
                   |> Multi.insert(
                     :bank,
                     bank_changeset(ctx.bank),
                     Keyword.merge(repo_opts, on_conflict: :nothing, conflict_target: [:id])
                   )
                   |> Multi.run(:file_storage, fn repo, _changes ->
                     upsert_file_storage(repo, extracted_items, repo_opts)
                   end)
                   |> Multi.run(:document_locks, fn repo, _changes ->
                     lock_replace_documents(repo, ctx.bank, extracted_items, repo_opts)
                   end)
                   |> Multi.run(:documents, fn repo, _changes ->
                     upsert_documents(repo, ctx.bank, extracted_items, repo_opts)
                   end)
                   |> Multi.run(:replace_documents, fn repo, _changes ->
                     replace_document_memory_units(repo, ctx.bank, extracted_items, repo_opts)
                   end)
                   |> Multi.run(:memory_units, fn repo, _changes ->
                     insert_prepared_memory_units(repo, prepared_memory_units, repo_opts)
                   end)
                   |> Multi.run(:entities, fn repo, %{memory_units: inserted} ->
                     materialize_entities(
                       repo,
                       ctx.bank,
                       Enum.zip(inserted, extracted_items),
                       entity_extractor(opts),
                       extractor_opts(opts),
                       embedder,
                       profile,
                       repo_opts
                     )
                   end)
                   |> Multi.run(:usage, fn _repo, _changes ->
                     {:ok, Foresight.Usage.report(Foresight.Usage.drain())}
                   end)
                   |> Multi.run(:audit_log, fn repo, %{usage: usage} ->
                     result =
                       retain_result(
                         %{base_result | "usage" => usage},
                         payload,
                         extraction_ms,
                         runtime_config_ms,
                         embedding_profile_ms,
                         prepare_memory_units_ms,
                         nil
                       )

                     insert_mutation_audit_log(
                       repo,
                       ctx,
                       "retain",
                       payload,
                       result,
                       repo_opts,
                       started_at
                     )
                   end)
                   |> repo.transaction(repo_opts)
                 end)
               end) do
          maybe_enqueue_auto_consolidation(ctx, extracted_items, opts, repo_opts)

          # Build the memory_links graph (semantic + temporal) post-commit, best-effort.
          # Runs its own reads/writes outside the retain
          # transaction so ANN probes never hold write locks or poison the retain;
          # still inline within with_tenant_scope so tenant prefix/role apply, which
          # is what makes the synchronous eval path get links without extra wiring.
          LinkConstruction.build_links(repo, ctx.bank, inserted, repo_opts)

          {:ok,
           retain_result(
             %{base_result | "items_count" => length(inserted), "usage" => usage},
             payload,
             extraction_ms,
             runtime_config_ms,
             embedding_profile_ms,
             prepare_memory_units_ms,
             transaction_ms
           )}
        else
          {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
            {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}

          {:error, _step, %Error{} = error, _changes} ->
            {:error, error}
        end
      end
    end)
  end

  @impl true
  def recall(ctx, %{"query" => query} = payload, opts) when is_binary(query) do
    repo = Keyword.fetch!(opts, :repo)
    embedder = Keyword.fetch!(opts, :embedder)
    reranker = Keyword.fetch!(opts, :reranker)
    repo_opts = tenant_repo_opts(ctx)

    # The query embedding (and any reranker call) may be chargeable; report it.
    Foresight.Usage.start()

    # Three DB-scoped phases with the model calls between them. In Mode C a tenant
    # scope is a checked-out connection (SET ROLE), and the pool's checkout timeout
    # (15 s by default) counts everything run inside it: with the embedder and the
    # cross-encoder inside the scope, a slow reranker on a large bank turned into a
    # dropped connection and a failed recall rather than a slow one. Nothing between
    # retrieval and result enrichment needs the database, so the scope is released
    # across the model calls and re-entered for the lookups. Mode A has no scope
    # and sees no difference; a caller already inside a scope (reflect's recall
    # tool) stays inside it, as before.
    with {:ok, prepared} <- recall_prepare(ctx, repo, repo_opts, payload, query, embedder, opts),
         {:ok, retrieved} <- recall_retrieve(ctx, repo, repo_opts, prepared, opts),
         {:ok, ranked} <- recall_rank(query, retrieved, reranker, opts),
         {:ok, enriched} <- recall_enrich(ctx, repo, repo_opts, payload, ranked, opts) do
      {:ok, recall_response(query, payload, enriched)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:internal, %{message: "recall failed: #{inspect(reason)}"})}
    end
  end

  def recall(_ctx, _payload, _opts) do
    {:error,
     Error.new(:invalid_request, %{message: "recall payload must include a query string"})}
  end

  # Phase 1 (scoped: bank config read only), then payload normalization, embedding
  # profile resolution and the query embedding outside the scope.
  defp recall_prepare(ctx, repo, repo_opts, payload, query, embedder, opts) do
    runtime_cfg = runtime_config(opts)

    {runtime_config, runtime_config_ms} =
      with_tenant_scope(ctx, repo, opts, fn ->
        timed_ms(fn -> resolve_runtime_bank_config(repo, ctx, repo_opts, runtime_cfg).config end)
      end)

    with {{:ok, normalized_params}, normalize_payload_ms} <-
           timed_ms(fn -> normalize_recall_payload(payload) end),
         {{:ok, profile}, embedding_profile_ms} <-
           timed_ms(fn ->
             EmbeddingProfile.resolve(runtime_config,
               embedder: embedder,
               runtime_config: runtime_cfg
             )
           end),
         params <-
           normalized_params
           |> Map.put("q", query)
           |> apply_runtime_recall_config(payload, runtime_config),
         {{:ok, query_embedding}, query_embedding_ms} <-
           timed_ms(fn ->
             embedder.embed(query, EmbeddingProfile.embedder_opts(profile))
           end) do
      {:ok,
       %{
         params: params,
         profile: profile,
         query_embedding: query_embedding,
         timings: %{
           "runtime_config_ms" => runtime_config_ms,
           "normalize_payload_ms" => normalize_payload_ms,
           "embedding_profile_ms" => embedding_profile_ms,
           "query_embedding_ms" => query_embedding_ms
         }
       }}
    else
      {{:error, reason}, _ms} -> {:error, reason}
    end
  end

  # Phase 2 (scoped): every retrieval arm, fusion, and the semantic candidate
  # selection. This is the only phase that reads memory units.
  defp recall_retrieve(ctx, repo, repo_opts, prepared, opts) do
    %{params: params, query_embedding: query_embedding, profile: profile} = prepared

    with_tenant_scope(ctx, repo, opts, fn ->
      case timed_ms(fn ->
             ranked_recall_items(repo, ctx, params, query_embedding, profile, repo_opts, opts)
           end) do
        {{:ok,
          %{
            items: candidates,
            strategies: strategy_trace,
            strategy_items: strategy_items,
            fused_strategy_items: fused_strategy_items
          }}, ranked_recall_ms} ->
          {:ok,
           prepared
           |> Map.merge(%{
             candidates: candidates,
             strategy_trace: strategy_trace,
             strategy_items: strategy_items,
             fused_strategy_items: fused_strategy_items
           })
           |> put_timing("ranked_recall_ms", ranked_recall_ms)}

        {{:error, reason}, _ms} ->
          {:error, reason}
      end
    end)
  end

  # Phase 3 (no scope): rerank window, cross-encoder, boosts, score cutoff, token
  # trim. The reranker is the slow call this pipeline exists to keep off the
  # connection.
  defp recall_rank(query, retrieved, reranker, opts) do
    %{params: params, candidates: candidates} = retrieved

    {rerank_candidates, rerank_candidates_ms} =
      timed_ms(fn -> prefilter_rerank_candidates(candidates, params) end)

    with {{:ok, reranked_items}, rerank_ms} <-
           timed_ms(fn -> reranker.rerank(query, rerank_candidates, opts) end),
         {boosted_items, boost_ms} <-
           timed_ms(fn -> boost_recall_items(reranked_items, params) end),
         cutoff_items <- maybe_filter_min_score(boosted_items, params["min_score"]),
         {{:ok, items}, trim_ms} <-
           timed_ms(fn -> trim_recall_items(cutoff_items, params["max_tokens"]) end) do
      {:ok,
       retrieved
       |> Map.merge(%{
         rerank_candidates: rerank_candidates,
         reranked_items: reranked_items,
         boosted_items: boosted_items,
         items: items
       })
       |> put_timing("rerank_candidates_ms", rerank_candidates_ms)
       |> put_timing("rerank_ms", rerank_ms)
       |> put_timing("boost_ms", boost_ms)
       |> put_timing("trim_ms", trim_ms)}
    else
      {{:error, reason}, _ms} -> {:error, reason}
    end
  end

  # Phase 4 (scoped): the lookups that decorate the final items — entity names,
  # entity states and source facts. Chunks and the candidate pool are derived
  # from data already in hand and are built outside the scope.
  defp recall_enrich(ctx, repo, repo_opts, payload, ranked, opts) do
    %{items: items} = ranked

    include_chunks = get_in(payload, ["include", "chunks"]) != nil
    include_source_facts = get_in(payload, ["include", "source_facts"]) != nil

    include_entities =
      get_in(payload, ["include", "entities"]) != nil or !Map.has_key?(payload, "include")

    with_tenant_scope(ctx, repo, opts, fn ->
      {entity_names_by_unit, entity_lookup_ms} =
        timed_ms(fn ->
          load_entity_names_by_unit(repo, Enum.map(items, & &1["id"]), repo_opts)
        end)

      {results, results_ms} =
        timed_ms(fn ->
          Enum.map(items, fn item ->
            recall_result_from_item(
              item,
              Map.get(entity_names_by_unit, item["id"], []),
              include_chunks
            )
          end)
        end)

      {entities_result, entities_ms} =
        timed_ms(fn ->
          if(include_entities,
            do: build_entity_states(repo, ctx.bank, results, repo_opts),
            else: nil
          )
        end)

      {source_facts_result, source_facts_ms} =
        timed_ms(fn ->
          if(include_source_facts,
            do: build_source_facts(repo, results, entity_names_by_unit, repo_opts),
            else: nil
          )
        end)

      {:ok,
       ranked
       |> Map.merge(%{
         results: results,
         entities_result: entities_result,
         source_facts_result: source_facts_result,
         include_chunks: include_chunks
       })
       |> put_timing("entity_lookup_ms", entity_lookup_ms)
       |> put_timing("results_ms", results_ms)
       |> put_timing("entities_ms", entities_ms)
       |> put_timing("source_facts_ms", source_facts_ms)}
    end)
  end

  defp put_timing(%{timings: timings} = acc, key, ms),
    do: %{acc | timings: Map.put(timings, key, ms)}

  # Assemble the response outside any scope: chunks, the optional candidate pool,
  # the always-on stats, the optional trace, and the usage ledger.
  defp recall_response(query, payload, enriched) do
    %{
      params: params,
      candidates: candidates,
      rerank_candidates: rerank_candidates,
      reranked_items: reranked_items,
      boosted_items: boosted_items,
      items: items,
      results: results,
      strategy_trace: strategy_trace,
      strategy_items: strategy_items,
      fused_strategy_items: fused_strategy_items,
      entities_result: entities_result,
      source_facts_result: source_facts_result,
      include_chunks: include_chunks,
      timings: timings
    } = enriched

    include_candidate_pool = candidate_pool_requested?(payload)

    {chunks_result, chunks_ms} =
      timed_ms(fn ->
        if(include_chunks, do: build_chunks(results), else: nil)
      end)

    {candidate_pool_result, candidate_pool_ms} =
      timed_ms(fn ->
        if include_candidate_pool do
          CandidatePool.pool(fused_strategy_items, candidate_pool_opts(payload))
        end
      end)

    timings =
      timings
      |> Map.put("chunks_ms", chunks_ms)
      |> maybe_put_present("candidate_pool_ms", if(include_candidate_pool, do: candidate_pool_ms))

    timings = Map.put(timings, "total_ms", timings |> Map.values() |> Enum.sum())

    response =
      %{
        "results" => results,
        "trace" =>
          if(payload["trace"],
            do:
              recall_trace(
                query,
                params,
                results,
                strategy_trace,
                strategy_items,
                candidates,
                rerank_candidates,
                reranked_items,
                boosted_items,
                items,
                timings
              )
          ),
        "entities" => entities_result,
        "chunks" => chunks_result,
        "source_facts" => source_facts_result,
        "stats" => recall_stats(params, candidates, rerank_candidates, items, timings)
      }

    response =
      if include_candidate_pool,
        do: Map.put(response, "candidate_pool", candidate_pool_result),
        else: response

    maybe_put_usage(response)
  end

  # The operator-facing summary of what recall did, present on every response (the
  # trace is opt-in and large). Enough to see a rerank window that is too wide for
  # the reranker in use, or a rerank stage that dominates the wall time, without
  # tracing every call.
  defp recall_stats(params, candidates, rerank_candidates, items, timings) do
    %{
      "candidates" => length(candidates),
      "rerank_window" => recall_rerank_window(params),
      "rerank_candidates" => length(rerank_candidates),
      "results" => length(items),
      "retrieval_ms" => Map.get(timings, "ranked_recall_ms", 0),
      "rerank_ms" => Map.get(timings, "rerank_ms", 0),
      "total_ms" => Map.get(timings, "total_ms", 0)
    }
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
  def reflect(ctx, %{"query" => query} = payload, opts) when is_binary(query) do
    timeout_ms = Keyword.get(opts, :reflect_timeout_ms, 120_000)
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      task =
        Task.async(fn ->
          reflect_once(ctx, query, payload, opts)
        end)

      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          result

        {:exit, reason} ->
          {:error, reflect_task_error(reason)}

        nil ->
          Task.shutdown(task, :brutal_kill)

          {:error,
           Error.new(:timeout, %{
             message: "reflect timed out after #{timeout_ms}ms"
           })}
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  def reflect(_ctx, _payload, _opts) do
    {:error,
     Error.new(:invalid_request, %{message: "reflect payload must include a query string"})}
  end

  defp reflect_once(ctx, query, payload, opts) do
    llm = Keyword.fetch!(opts, :llm)

    # Agentic tool-calling reflect is the default when the provider supports it;
    # the fixed structured pipeline is the fallback for budget: low and for
    # providers/fakes without native tool-calling. 
    if use_agentic_reflect?(llm, payload) do
      reflect_agentic(ctx, query, payload, opts)
    else
      reflect_fixed_once(ctx, query, payload, opts)
    end
  end

  defp use_agentic_reflect?(llm, payload) do
    Foresight.LLM.supports_tool_calling?(llm) and reflect_budget(payload) != "low"
  end

  defp reflect_budget(payload) do
    case Map.get(payload, "budget") do
      budget when is_binary(budget) -> String.downcase(budget)
      _other -> nil
    end
  end

  defp reflect_fixed_once(ctx, query, payload, opts) do
    llm = Keyword.fetch!(opts, :llm)
    repo = Keyword.fetch!(opts, :repo)
    started_at_ms = monotonic_ms()
    repo_opts = tenant_repo_opts(ctx)

    runtime_config =
      with_tenant_scope(ctx, repo, opts, fn ->
        resolve_runtime_bank_config(repo, ctx, repo_opts, runtime_config(opts)).config
      end)

    opts = Keyword.put(opts, :resolved_runtime_config, runtime_config)
    observations = reflect_observations(repo, ctx, payload, opts)
    max_iterations = reflect_max_iterations(payload, opts)

    with {{:ok, recall_result}, recall_ms} <-
           timed_ms(fn -> recall(ctx, with_reflect_recall_budget(payload), opts) end),
         {:ok, bank_profile} <- bank_profile(ctx, ctx.bank, opts),
         bank_profile <- apply_runtime_reflect_bank_profile(bank_profile, runtime_config),
         directives <- active_directives(repo, ctx, ctx.bank, payload, repo_opts, opts),
         mental_models <- active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts),
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
               llm_call_opts(opts)
             )
           end),
         {{:ok, loop_state}, loop_ms} <-
           timed_ms(fn ->
             run_reflect_loop(
               ctx,
               payload,
               opts,
               repo,
               repo_opts,
               llm,
               bank_profile,
               directives,
               mental_models,
               recall_result,
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
               repo,
               repo_opts,
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
                 maybe_structured_reflect_output(llm, query, final_text, payload, opts)
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
               "directives" => Enum.map(directives, &directive_to_based_on/1)
             },
             "structured_output" => structured_output,
             "usage" => usage_from_llm_calls(llm_calls),
             "trace" => %{
               "tool_calls" => reflect_tool_calls(loop_state.tool_calls, payload),
               "llm_calls" => llm_calls,
               "directives_applied" => Enum.map(directives, & &1.name),
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
               "budget" => to_string(Map.get(payload, "budget", "mid")),
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
    else
      # A provider error (local LLM endpoint unloaded the model, returned a
      # non-JSON body, timed out) must degrade to a clean {:error, Error.t()}.
      # Otherwise a timed_ms clause leaks the raw {{:error, _}, ms} tuple, which
      # matches neither {:ok, _} nor {:error, _} upstream and crashes the caller.
      {{:error, reason}, _ms} -> {:error, normalize_reflect_provider_error(reason)}
      {:error, reason} -> {:error, normalize_reflect_provider_error(reason)}
    end
  end

  defp normalize_reflect_provider_error(%Error{} = error), do: error

  defp normalize_reflect_provider_error(reason) do
    Error.new(:unavailable, %{message: "reflect llm provider error: #{inspect(reason)}"})
  end

  # ---- agentic (tool-calling) reflect ------------------------------

  # Runs Hindsight's agentic reflect on the in-house LlmCore.Agent.Loop: the LLM
  # chooses retrieval tools each turn until it answers in plain text. Forced
  # retrievals (observations + initial recall) are pre-seeded so evidence always
  # exists. LLM calls happen here, OUTSIDE any DB transaction; each tool
  # dispatch is its own tenant-scoped read.
  defp reflect_agentic(ctx, query, payload, opts) do
    llm = Keyword.fetch!(opts, :llm)
    repo = Keyword.fetch!(opts, :repo)
    started_at_ms = monotonic_ms()
    repo_opts = tenant_repo_opts(ctx)

    runtime_config =
      with_tenant_scope(ctx, repo, opts, fn ->
        resolve_runtime_bank_config(repo, ctx, repo_opts, runtime_config(opts)).config
      end)

    opts = Keyword.put(opts, :resolved_runtime_config, runtime_config)

    with {:ok, bank_profile} <- bank_profile(ctx, ctx.bank, opts),
         {:ok, recall_result} <-
           recall(ctx, with_reflect_recall_budget(payload), opts) do
      bank_profile = apply_runtime_reflect_bank_profile(bank_profile, runtime_config)
      directives = active_directives(repo, ctx, ctx.bank, payload, repo_opts, opts)
      mental_models = active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts)
      seeded_mental_models = seed_mental_models(repo, ctx, mental_models, query, opts)
      observations = reflect_observations(repo, ctx, payload, opts)

      reset_reflect_grounding()
      seed_reflect_grounding(observations, recall_result)
      add_reflect_grounding(:mental_model, Enum.map(seeded_mental_models, & &1["id"]))

      system_prompt =
        Foresight.Prompts.Reflect.Agent.V1.system_prompt(
          bank_profile: bank_profile,
          directives: directives,
          has_mental_models: mental_models != [],
          include_observations: true,
          budget: reflect_budget(payload),
          finish_with_done: true
        )

      messages = [
        %{role: :system, content: system_prompt},
        %{
          role: :user,
          content:
            "Question: #{query}\n\n" <>
              format_reflect_preseed(observations, recall_result, seeded_mental_models)
        }
      ]

      tools =
        Foresight.Prompts.Reflect.Tools.build(
          mental_models: mental_models != [],
          observations: true,
          # Terminal `done` tool : the LLM declares its answer + the ids
          # it actually used; llm_core's terminal_tool ends the loop on that call
          # (never dispatched). Citations become LLM-selected, not all-retrieved.
          done: true
        )

      base_llm_opts = reflect_agent_llm_opts(opts)
      resolver = fn call -> resolve_reflect_tool(call, ctx, payload, opts) end

      llm_send = fn msgs, send_opts ->
        result = llm.complete_with_tools(msgs, Keyword.merge(base_llm_opts, send_opts))

        case result do
          {:ok, response} -> record_reflect_llm_usage(response.usage)
          _other -> :ok
        end

        result
      end

      max_iterations = reflect_max_iterations(payload, opts)

      loop_opts =
        [
          tools: tools,
          resolve_tool: resolver,
          terminal_tool: "done",
          max_iterations: max_iterations
        ]
        |> Foresight.Reflect.LoopOptions.with_pipeline_opts(
          Keyword.get(opts, :agent_pipeline_opts)
        )

      # Run the loop under the grounding gate. When an entailment verifier
      # is configured, each answer's clauses are checked against its cited memories; an
      # ungrounded answer re-enters the loop (targeting the unsupported clauses) instead
      # of being accepted. Default verifier is Noop → this is a plain Loop.run.
      case run_agentic_loop_grounded(messages, llm_send, loop_opts, opts) do
        {:ok, response, gate} ->
          {:ok,
           build_agentic_reflect_result(
             response,
             payload,
             directives,
             recall_result,
             mental_models,
             max_iterations,
             started_at_ms
           )
           |> attach_entailment_trace(gate)}

        # Loop exhaustion / error. Faithful to Hindsight's reflect/agent.py, which
        # FORCES a final synthesis from the accumulated context on the last iteration
        # rather than giving up: when the loop already gathered evidence (pre-seed +
        # tool recalls), synthesize the answer from THAT instead of discarding it and
        # re-running the fixed pipeline from scratch (which re-recalls and often
        # returns "no grounded information" — the Mode-B failure mode). Only
        # when nothing was gathered do we degrade to the fixed structured pipeline.
        {:error, _reason} ->
          case reflect_agentic_forced_synthesis(
                 llm,
                 query,
                 payload,
                 base_llm_opts,
                 bank_profile,
                 directives,
                 mental_models,
                 max_iterations,
                 started_at_ms
               ) do
            {:ok, result} -> {:ok, result}
            :no_evidence -> reflect_fixed_once(ctx, query, payload, opts)
          end
      end
    end
  end

  # Hindsight's forced-final-synthesis, ported to Foresight: answer from the RAW
  # MEMORY FACTS the agentic loop already recalled (process-dict `reflect_memory_items`)
  # with a tools-less LLM call, so an exhausted loop never throws away what it
  # retrieved. Only recalled memories are injected as evidence (observation *content*
  # is not accumulated in the process dict, only ids), so we gate on memories: no
  # recalled facts → `:no_evidence`, and the caller degrades to the fixed pipeline,
  # which re-recalls from scratch rather than synthesizing from nothing.
  defp reflect_agentic_forced_synthesis(
         llm,
         query,
         payload,
         base_llm_opts,
         bank_profile,
         directives,
         mental_models,
         max_iterations,
         started_at_ms
       ) do
    memory_items = reflect_memory_items() |> Enum.uniq_by(& &1["id"])

    if memory_items == [] do
      :no_evidence
    else
      system_prompt =
        Foresight.Prompts.Reflect.Agent.V1.system_prompt(
          bank_profile: bank_profile,
          directives: directives,
          has_mental_models: mental_models != [],
          include_observations: true,
          budget: reflect_budget(payload)
        )

      evidence =
        "PRE-RETRIEVED MEMORIES (raw facts):\n" <>
          Jason.encode!(Enum.map(memory_items, &reflect_tool_memory/1))

      messages = [
        %{role: :system, content: system_prompt},
        %{
          role: :user,
          content:
            "Question: #{query}\n\n#{evidence}\n\nYou have gathered all the evidence " <>
              "available. Answer the question NOW in plain text using ONLY this evidence. " <>
              "Do not call any tools."
        }
      ]

      case llm.complete_with_tools(messages, Keyword.put(base_llm_opts, :tools, [])) do
        {:ok, response} ->
          record_reflect_llm_usage(response.usage)

          result =
            build_agentic_reflect_result(
              response,
              payload,
              directives,
              nil,
              mental_models,
              max_iterations,
              started_at_ms
            )

          {:ok, put_in(result, ["trace", "termination"], "forced_synthesis")}

        {:error, _reason} ->
          :no_evidence
      end
    end
  end

  # Tenant-scoped tool dispatch. Never raises out to the loop — a tool failure
  # becomes {:error, msg}, which the loop tolerates (and breaks out on repeat).
  defp resolve_reflect_tool(
         %LlmToolkit.Tool.Call{name: name, arguments: args},
         ctx,
         payload,
         opts
       ) do
    record_reflect_tool_call(name, args)

    case name do
      "recall" -> tool_recall(args, ctx, payload, opts)
      "search_observations" -> tool_search_observations(args, ctx, payload, opts)
      "search_mental_models" -> tool_search_mental_models(args, ctx, payload, opts)
      "expand" -> tool_expand(args, ctx, opts)
      other -> {:error, "unknown tool: #{other}"}
    end
  rescue
    error -> {:error, "tool #{name} failed: #{Exception.message(error)}"}
  end

  defp tool_recall(args, ctx, payload, opts) do
    # Honor the recall tool's own max_tokens (default @reflect_recall_max_tokens),
    # NOT the reflect payload's answer cap — inheriting the latter starved every tool
    # recall the same way the pre-seed was starved.
    recall_payload =
      payload
      |> Map.merge(%{"query" => args["query"] || ""})
      |> Map.put("max_tokens", recall_tool_budget(args["max_tokens"]))

    case recall(ctx, recall_payload, opts) do
      {:ok, %{"results" => results}} ->
        add_reflect_grounding(:memory, grounding_ids(results))
        add_reflect_memory_items(results)
        {:ok, Jason.encode!(%{"memories" => Enum.map(results, &reflect_tool_memory/1)})}

      _other ->
        {:ok, Jason.encode!(%{"memories" => []})}
    end
  end

  # Vector-semantic observation search : route through the full
  # recall/3 pipeline (semantic + keyword + RRF + rerank) scoped to
  # fact_type=:observation, so consolidated knowledge is retrieved by SEMANTIC
  # relevance to the tool's query rather than keyword-filtered. recall_base_query
  # honors `types` via maybe_filter_type, and consolidation embeds observations under their
  # source facts' embedding profile, so recall's semantic arm surfaces them.
  # Honors the tool's max_tokens; the caller's tag scope (payload["tags"]) flows
  # through recall's normalizer, preserving sub-bank isolation.
  defp tool_search_observations(args, ctx, payload, opts) do
    query = args["query"] || payload["query"] || ""

    recall_payload =
      payload
      |> Map.merge(%{"query" => query, "types" => ["observation"]})
      |> maybe_put_observation_budget(args["max_tokens"])

    case recall(ctx, recall_payload, opts) do
      {:ok, %{"results" => results}} ->
        add_reflect_grounding(:observation, grounding_ids(results))
        {:ok, Jason.encode!(%{"observations" => Enum.map(results, &reflect_tool_observation/1)})}

      _other ->
        {:ok, Jason.encode!(%{"observations" => []})}
    end
  end

  # The agent loop passes the LLM's literal tool arguments without filling schema
  # defaults, so apply the advertised observation budget here when the model omits
  # it, and coerce string/float budgets the way the rest of the system tolerates
  # scalars — rather than silently dropping them.
  defp maybe_put_observation_budget(params, max_tokens) do
    Map.put(params, "max_tokens", observation_budget(max_tokens))
  end

  defp observation_budget(value) when is_integer(value) and value > 0, do: value
  defp observation_budget(value) when is_float(value) and value >= 1.0, do: trunc(value)

  defp observation_budget(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> int
      _ -> @reflect_observation_max_tokens
    end
  end

  defp observation_budget(_value), do: @reflect_observation_max_tokens

  # search_mental_models result cap. Mirrors Prompts.Reflect.Tools' advertised
  # default (5) and coerces string/float scalars like the rest of the system, so a
  # model that omits or fudges max_results still gets a sane, bounded result set.
  defp mental_model_search_limit(value) when is_integer(value) and value > 0, do: value
  defp mental_model_search_limit(value) when is_float(value) and value >= 1.0, do: trunc(value)

  defp mental_model_search_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> int
      _ -> @default_mental_model_search_limit
    end
  end

  defp mental_model_search_limit(_value), do: @default_mental_model_search_limit

  # Recall evidence budget for the agentic `recall` tool. Coerces string/float scalars
  # like the rest of the system, and defaults to @reflect_recall_max_tokens when the
  # model omits it (or provides a sub-floor value) — never inheriting the reflect
  # answer cap, and never collapsing recall to a token or two (audit finding).
  defp recall_tool_budget(value) when is_integer(value) and value >= @reflect_recall_min_tokens,
    do: value

  defp recall_tool_budget(value) when is_float(value) and value >= @reflect_recall_min_tokens,
    do: trunc(value)

  defp recall_tool_budget(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int >= @reflect_recall_min_tokens -> int
      _ -> @reflect_recall_max_tokens
    end
  end

  defp recall_tool_budget(_value), do: @reflect_recall_max_tokens

  # Route every reflect-INTERNAL recall (agentic pre-seed, and the fixed path's
  # initial recall + focus_query loop/replan recalls) through the dedicated evidence
  # budget. The agentic path fixed this at its pre-seed, but the fixed pipeline was
  # still starved at its initial recall and every focus_query recall — a small answer
  # `max_tokens` trimmed the evidence feeding the plan + synthesis (audit
  # MAJOR).
  defp with_reflect_recall_budget(payload) do
    Map.put(payload, "max_tokens", @reflect_recall_max_tokens)
  end

  # Hindsight's tool_search_mental_models: semantic rank over the models' embeddings,
  # capped by max_results, each with a per-model staleness verdict. See
  # Foresight.Reflect.MentalModels.
  defp tool_search_mental_models(args, ctx, payload, opts) do
    repo = Keyword.fetch!(opts, :repo)
    repo_opts = tenant_repo_opts(ctx)
    query = args["query"] || payload["query"] || ""
    limit = mental_model_search_limit(args["max_results"])

    mental_models =
      with_tenant_scope(ctx, repo, opts, fn ->
        repo
        |> active_mental_model_documents(ctx.bank, payload, repo_opts)
        |> then(
          &Foresight.Reflect.MentalModels.search(
            repo,
            ctx.bank,
            &1,
            query,
            limit,
            mental_model_search_opts(repo, ctx, repo_opts, opts)
          )
        )
      end)

    add_reflect_grounding(:mental_model, Enum.map(mental_models, & &1["id"]))

    {:ok,
     Jason.encode!(%{
       "query" => query,
       "count" => length(mental_models),
       "mental_models" => mental_models
     })}
  end

  defp mental_model_search_opts(repo, ctx, repo_opts, opts) do
    [
      repo_opts: repo_opts,
      profile: reflect_embedding_profile(repo, ctx, repo_opts, opts),
      embedder: Keyword.get(opts, :embedder)
    ]
  end

  # The bank's embedding profile for reflect-side embedding (mental models). Runs
  # inside the caller's tenant scope. nil when it cannot be resolved, in which case
  # mental-model search falls back to lexical ranking.
  defp reflect_embedding_profile(repo, ctx, repo_opts, opts) do
    runtime_cfg = runtime_config(opts)

    resolved =
      Keyword.get(opts, :resolved_runtime_config) ||
        resolve_runtime_bank_config(repo, ctx, repo_opts, runtime_cfg).config

    case Keyword.get(opts, :embedder) do
      nil ->
        nil

      embedder ->
        case EmbeddingProfile.resolve(resolved, embedder: embedder, runtime_config: runtime_cfg) do
          {:ok, profile} -> profile
          {:error, _error} -> nil
        end
    end
  rescue
    _error -> nil
  end

  # Mental models to seed into the agentic opening context: the top few by semantic
  # relevance to the question (Hindsight forces a search_mental_models call first;
  # the loop here cannot force a tool, so the equivalent evidence is pre-retrieved).
  @reflect_preseed_mental_models 3

  defp seed_mental_models(_repo, _ctx, [], _query, _opts), do: []

  defp seed_mental_models(repo, ctx, mental_models, query, opts) do
    repo_opts = tenant_repo_opts(ctx)

    with_tenant_scope(ctx, repo, opts, fn ->
      Foresight.Reflect.MentalModels.search(
        repo,
        ctx.bank,
        mental_models,
        query,
        @reflect_preseed_mental_models,
        mental_model_search_opts(repo, ctx, repo_opts, opts)
      )
    end)
  rescue
    _error -> []
  end

  # `depth` is honoured ("chunk": provenance + neighbouring chunks of the same
  # document; "document": the owning document's title and text) and the
  # model-controlled id list is capped. See Foresight.Reflect.Expand.
  defp tool_expand(args, ctx, opts) do
    repo = Keyword.fetch!(opts, :repo)
    depth = Foresight.Reflect.Expand.depth(args["depth"])

    expanded =
      with_tenant_scope(ctx, repo, opts, fn ->
        Foresight.Reflect.Expand.expand(
          repo,
          ctx.bank,
          args["memory_ids"],
          depth,
          tenant_repo_opts(ctx)
        )
      end)

    # What the model was shown is citable: the expanded units and their neighbours.
    add_reflect_grounding(:memory, Foresight.Reflect.Expand.cited_ids(expanded))

    {:ok, Jason.encode!(%{"depth" => depth, "expanded" => expanded})}
  end

  defp build_agentic_reflect_result(
         response,
         payload,
         directives,
         _recall_result,
         mental_models,
         max_iterations,
         started_at_ms
       ) do
    retrieved = reflect_grounding()
    terminal_args = reflect_terminal_args(response)

    # LLM-selected citations : when the loop ended via the terminal
    # `done` tool, cite only the ids the model declared AND that were retrieved —
    # dropping over-citation (retrieved but unused) and hallucinations (cited but
    # never retrieved). Absent a done call (plain-text answer, or the forced-final
    # synthesis path), fall back to the full retrieved set.
    grounding =
      case terminal_args do
        nil -> retrieved
        args -> Foresight.Reflect.CitationSelection.select(args, retrieved)
      end

    # based_on.memories must describe every CITED memory (from the pre-seed or a
    # tool recall) — use the accumulated result maps, scoped to the grounding set.
    based_on_memories =
      reflect_memory_items()
      |> Enum.filter(&(to_string(&1["id"]) in grounding.memory))
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(&based_on_memory/1)

    based_on_mental_models =
      mental_models
      |> Enum.filter(&(to_string(&1.external_id || &1.id) in grounding.mental_model))
      |> Enum.map(&mental_model_to_based_on/1)

    %{
      "text" => agentic_answer_text(response, terminal_args),
      "memory_ids" => grounding.memory,
      "mental_model_ids" => grounding.mental_model,
      "observation_ids" => grounding.observation,
      "based_on" => %{
        "memories" => based_on_memories,
        "mental_models" => based_on_mental_models,
        "directives" => Enum.map(directives, &directive_to_based_on/1)
      },
      "structured_output" => nil,
      "usage" => reflect_accumulated_usage(),
      "trace" => %{
        "mode" => "agentic",
        "tool_calls" => reflect_recorded_tool_calls(),
        "tools_called" => length(reflect_recorded_tool_calls()),
        "budget" => to_string(reflect_budget(payload) || "mid"),
        "max_iterations" => max_iterations,
        "termination" => "answered",
        "timings_ms" => %{"total_ms" => monotonic_ms() - started_at_ms}
      }
    }
  end

  # Raw arguments of the terminal `done` call , surfaced by llm_core's
  # terminal_tool on the response metadata; nil when the loop ended another way
  # (plain-text answer, forced-final synthesis).
  defp reflect_terminal_args(response) do
    with metadata when is_map(metadata) <- Map.get(response, :metadata),
         args when is_map(args) <- Map.get(metadata, :terminal_args) do
      args
    else
      _ -> nil
    end
  end

  defp agentic_answer_text(_response, %{"answer" => answer})
       when is_binary(answer) and answer != "",
       do: answer

  defp agentic_answer_text(response, _terminal_args), do: response.content || ""

  # -- grounded reflect via the entailment gate -----------------------

  # Run the agentic loop, then (if a verifier is configured) gate the answer's clauses
  # against its cited-memory evidence. An ungrounded answer re-enters the loop with a
  # corrective message naming the unsupported clauses, up to a bounded number of
  # re-entries; grounding/evidence accumulate across re-entries (process-local). Returns
  # `{:ok, response, gate_or_nil}` or the loop's `{:error, _}` (→ forced synthesis).
  defp run_agentic_loop_grounded(messages, llm_send, loop_opts, opts) do
    gate_opts = entailment_gate_opts(opts)

    if entailment_enabled?(gate_opts) do
      do_agentic_loop_grounded(
        messages,
        llm_send,
        loop_opts,
        gate_opts,
        entailment_max_reentries(opts)
      )
    else
      case LlmCore.Agent.Loop.run(messages, llm_send, loop_opts) do
        {:ok, response, _final} -> {:ok, response, nil}
        {:error, _reason} = err -> err
      end
    end
  end

  defp do_agentic_loop_grounded(messages, llm_send, loop_opts, gate_opts, reentries) do
    case LlmCore.Agent.Loop.run(messages, llm_send, loop_opts) do
      {:ok, response, final_messages} ->
        {answer, evidence} = reflect_answer_and_evidence(response)
        gate = EntailmentGate.check(answer, evidence, gate_opts)

        if gate.passed? or reentries <= 0 do
          {:ok, response, gate}
        else
          corrective = %{role: :user, content: entailment_corrective(gate.unsupported_clauses)}

          do_agentic_loop_grounded(
            final_messages ++ [corrective],
            llm_send,
            loop_opts,
            gate_opts,
            reentries - 1
          )
        end

      {:error, _reason} = err ->
        err
    end
  end

  # The answer text plus the text of the memories it CITED (via the done tool; the full
  # retrieved set when no citations were declared) — the evidence the gate checks the
  # answer against.
  defp reflect_answer_and_evidence(response) do
    terminal_args = reflect_terminal_args(response)
    answer = agentic_answer_text(response, terminal_args)
    retrieved = reflect_grounding()

    grounding =
      case terminal_args do
        nil -> retrieved
        args -> Foresight.Reflect.CitationSelection.select(args, retrieved)
      end

    evidence =
      reflect_memory_items()
      |> Enum.filter(&(to_string(&1["id"]) in grounding.memory))
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(&(&1["text"] || &1["content"]))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    {answer, evidence}
  end

  defp entailment_corrective(unsupported_clauses) do
    "Grounding check: the following statements in your answer are NOT supported by the " <>
      "memories you cited:\n" <>
      Enum.map_join(unsupported_clauses, "\n", &"- #{&1}") <>
      "\n\nUse the recall or search tools to find evidence that supports them, or remove " <>
      "them. Then give your final answer via the done tool, citing the memories that " <>
      "support each remaining claim."
  end

  defp attach_entailment_trace(result, nil), do: result

  defp attach_entailment_trace(result, gate) do
    put_in(result, ["trace", "entailment"], %{
      "passed" => gate.passed?,
      "clauses" => length(gate.clauses),
      "unsupported" => gate.unsupported_clauses
    })
  end

  # The verifier is off (no gate) unless explicitly configured to something other than
  # Noop — via opts (tests) or the `:entailment_verifier` app config.
  defp entailment_enabled?(gate_opts) do
    case Keyword.get(gate_opts, :entailment_verifier) do
      nil -> false
      NoopVerifier -> false
      _module -> true
    end
  end

  # Gate opts assembled from app config (verifier choice, policy, NLI threshold/serving)
  # plus the reflect LLM handle + provider hints (the LLM-judge verifier needs them).
  defp entailment_gate_opts(opts) do
    verifier =
      Keyword.get(opts, :entailment_verifier) ||
        Application.get_env(:foresight, :entailment_verifier, NoopVerifier)

    [
      entailment_verifier: verifier,
      entailment_min_supported:
        Keyword.get(opts, :entailment_min_supported) ||
          Application.get_env(:foresight, :entailment_min_supported, 1.0),
      entailment_nli_threshold: Application.get_env(:foresight, :entailment_nli_threshold, 0.5),
      entailment_serving_name:
        get_in(Application.get_env(:foresight, :ml, []), [:entailment_serving_name]),
      llm: Keyword.get(opts, :llm),
      provider: Keyword.get(opts, :provider),
      provider_opts: Keyword.get(opts, :provider_opts)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp entailment_max_reentries(opts) do
    Keyword.get(opts, :entailment_max_reentries) ||
      Application.get_env(:foresight, :entailment_max_reentries, 1)
  end

  # -- agentic reflect: grounding accumulation (process-local; loop is sync) ----

  defp reset_reflect_grounding do
    Process.put(:reflect_grounding, %{memory: [], observation: [], mental_model: []})
    Process.put(:reflect_memory_items, [])
    Process.put(:reflect_tool_calls, [])
    Process.put(:reflect_llm_usage, [])
  end

  # Record the token usage of each LLM call the agentic loop makes, so the result
  # reports the SUM across the whole loop (not the last call, not a hardcoded %{}).
  # This is the token/cost accounting the now-DEFAULT agentic path zeroed — the
  # input per-tenant cost reporting needs.
  defp record_reflect_llm_usage(usage) when is_map(usage) do
    Process.put(:reflect_llm_usage, [usage | Process.get(:reflect_llm_usage, [])])
    :ok
  end

  defp record_reflect_llm_usage(_usage), do: :ok

  defp reflect_accumulated_usage do
    Process.get(:reflect_llm_usage, [])
    |> Enum.reduce(%{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}, fn u, acc ->
      input = usage_token(u, [:prompt_tokens, "prompt_tokens", :input_tokens, "input_tokens"])

      output =
        usage_token(u, [:completion_tokens, "completion_tokens", :output_tokens, "output_tokens"])

      %{
        "input_tokens" => acc["input_tokens"] + input,
        "output_tokens" => acc["output_tokens"] + output,
        "total_tokens" => acc["total_tokens"] + input + output
      }
    end)
  end

  defp usage_token(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(usage, key) do
        n when is_number(n) -> n
        _ -> nil
      end
    end)
  end

  # Record each tool the agentic loop actually executed, so the result trace can
  # report real behaviour (how many tools, which queries) instead of a hardcoded
  # empty list. This is the observability that distinguishes "answered from the
  # pre-seed on iteration 1 with zero tools" from "ran real tool-calling" — the
  # blindness that hid the multi-session under-retrieval gap.
  defp record_reflect_tool_call(name, args) do
    entry = %{
      "tool" => name,
      "query" => is_map(args) && (args["query"] || args[:query]),
      "reason" => is_map(args) && (args["reason"] || args[:reason])
    }

    Process.put(:reflect_tool_calls, [entry | Process.get(:reflect_tool_calls, [])])
  end

  defp reflect_recorded_tool_calls do
    Process.get(:reflect_tool_calls, []) |> Enum.reverse()
  end

  defp seed_reflect_grounding(observations, recall_result) do
    add_reflect_grounding(:observation, grounding_ids(observations["observations"]))
    add_reflect_grounding(:memory, grounding_ids(recall_result["results"]))
    add_reflect_memory_items(recall_result["results"])
  end

  defp add_reflect_grounding(kind, ids) do
    grounding = reflect_grounding()
    Process.put(:reflect_grounding, Map.update(grounding, kind, ids, &Enum.uniq(&1 ++ ids)))
  end

  defp reflect_grounding do
    Process.get(:reflect_grounding, %{memory: [], observation: [], mental_model: []})
  end

  # Accumulates the full recalled memory result maps (seed + tool recalls) so
  # based_on.memories can describe every grounded memory id.
  defp add_reflect_memory_items(items) when is_list(items) do
    Process.put(:reflect_memory_items, Process.get(:reflect_memory_items, []) ++ items)
  end

  defp add_reflect_memory_items(_items), do: :ok

  defp reflect_memory_items, do: Process.get(:reflect_memory_items, [])

  defp grounding_ids(items) when is_list(items) do
    items |> Enum.map(&(&1["id"] || &1[:id])) |> Enum.reject(&is_nil/1) |> Enum.map(&to_string/1)
  end

  defp grounding_ids(_items), do: []

  # -- agentic reflect: tool-result + pre-seed formatting ----------------------

  defp format_reflect_preseed(observations, recall_result, mental_models) do
    obs = observations["observations"] || []
    mems = recall_result["results"] || []

    mm_block =
      if mental_models == [],
        do: "",
        else:
          "PRE-RETRIEVED MENTAL MODELS (curated syntheses, most relevant first; " <>
            "trust these over raw facts unless stale):\n" <>
            Jason.encode!(mental_models) <> "\n\n"

    obs_block =
      if obs == [],
        do: "",
        else:
          "PRE-RETRIEVED OBSERVATIONS (consolidated knowledge):\n" <>
            Jason.encode!(Enum.map(obs, &reflect_tool_observation/1)) <> "\n\n"

    mem_block =
      if mems == [],
        do: "",
        else:
          "PRE-RETRIEVED MEMORIES (raw facts):\n" <>
            Jason.encode!(Enum.map(mems, &reflect_tool_memory/1)) <> "\n\n"

    case mm_block <> obs_block <> mem_block do
      "" ->
        "No pre-retrieval available; use the tools to gather evidence before answering."

      body ->
        "You already have these retrievals. Use the tools to gather more if needed, then answer.\n\n" <>
          body
    end
  end

  defp reflect_tool_memory(item) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "mentioned_at" => item["mentioned_at"] || item["date"],
      "occurred_start" => item["occurred_start"],
      "occurred_end" => item["occurred_end"]
    }
    |> reject_nil_values()
  end

  defp reflect_tool_observation(item) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "mentioned_at" => item["mentioned_at"] || item["date"]
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp reflect_agent_llm_opts(opts) do
    Keyword.take(opts, [:provider, :provider_opts, :sleep_ms])
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
               llm_call_opts(opts)
             )
           end),
         cleaned_text = clean_reflect_answer_text(text),
         {{:ok, rewritten_text, rewrite_trace}, rewrite_ms} <-
           timed_ms(fn ->
             maybe_rewrite_reflect_text(llm, query, cleaned_text, payload, opts)
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
             maybe_structured_reflect_output(llm, query, disciplined_text, payload, opts)
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
             |> filter_grounded_mental_models(grounding_validation)
             |> Enum.map(&mental_model_to_based_on/1),
           "directives" => Enum.map(directives, &directive_to_based_on/1)
         },
         "structured_output" => structured_output,
         "usage" => usage_from_llm_calls(llm_calls),
         "trace" => %{
           "tool_calls" => reflect_tool_calls(loop_state.tool_calls, payload),
           "llm_calls" => llm_calls,
           "directives_applied" => Enum.map(directives, & &1.name),
           "directive_compliance" => disciplined_directive_compliance,
           "mental_models_considered" => Enum.map(loop_state.mental_models, & &1.external_id),
           "grounding_validation" => grounding_validation,
           "evidence_discipline" => evidence_discipline,
           "reflect_branch" => reflect_branch,
           "reflect_overview" => reflect_overview,
           "budget" => to_string(Map.get(payload, "budget", "mid")),
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
  def list_banks(ctx, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      banks =
        repo.all(from(bank in Bank, order_by: [asc: bank.id]), repo_opts)
        |> Enum.map(&bank_to_response(&1, repo, repo_opts))

      {:ok, banks}
    end)
  rescue
    error in DBConnection.ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  @impl true
  def put_bank(ctx, bank_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()
      normalized_attrs = normalize_bank_attrs(bank_id, attrs)

      changeset =
        bank_id
        |> bank_record(repo, repo_opts)
        |> Bank.changeset(normalized_attrs)

      repo.transaction(
        fn ->
          with {:ok, bank} <- repo.insert_or_update(changeset, repo_opts),
               response = bank_profile_response(bank),
               {:ok, _audit_log} <-
                 insert_mutation_audit_log(
                   repo,
                   ctx,
                   "put_bank",
                   normalized_attrs,
                   response,
                   repo_opts,
                   started_at
                 ) do
            response
          else
            {:error, %Ecto.Changeset{} = changeset} ->
              repo.rollback(Error.new(:invalid_request, %{message: format_changeset(changeset)}))

            {:error, %Error{} = error} ->
              repo.rollback(error)
          end
        end,
        repo_opts
      )
      |> normalize_transaction_result()
    end)
  end

  @impl true
  def patch_bank(ctx, bank_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()
      normalized_attrs = normalize_patch_bank_attrs(attrs)

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        %Bank{} = bank ->
          repo.transaction(
            fn ->
              with {:ok, updated_bank} <-
                     bank
                     |> Bank.changeset(normalized_attrs)
                     |> repo.update(repo_opts),
                   response = bank_profile_response(updated_bank),
                   {:ok, _audit_log} <-
                     insert_mutation_audit_log(
                       repo,
                       ctx,
                       "patch_bank",
                       normalized_attrs,
                       response,
                       repo_opts,
                       started_at
                     ) do
                response
              else
                {:error, %Ecto.Changeset{} = changeset} ->
                  repo.rollback(
                    Error.new(:invalid_request, %{message: format_changeset(changeset)})
                  )

                {:error, %Error{} = error} ->
                  repo.rollback(error)
              end
            end,
            repo_opts
          )
          |> normalize_transaction_result()
      end
    end)
  end

  @impl true
  def update_bank_disposition(ctx, bank_id, disposition, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        %Bank{} = bank ->
          repo.transaction(
            fn ->
              with {:ok, updated_bank} <-
                     bank
                     |> Bank.changeset(%{disposition: disposition})
                     |> repo.update(repo_opts),
                   response = bank_profile_response(updated_bank),
                   {:ok, _audit_log} <-
                     insert_mutation_audit_log(
                       repo,
                       ctx,
                       "update_bank_disposition",
                       %{"disposition" => disposition},
                       response,
                       repo_opts,
                       started_at
                     ) do
                response
              else
                {:error, %Ecto.Changeset{} = changeset} ->
                  repo.rollback(
                    Error.new(:invalid_request, %{message: format_changeset(changeset)})
                  )

                {:error, %Error{} = error} ->
                  repo.rollback(error)
              end
            end,
            repo_opts
          )
          |> normalize_transaction_result()
      end
    end)
  end

  @impl true
  def add_bank_background(ctx, bank_id, content, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        %Bank{} = bank ->
          merged_mission = merge_bank_background(bank.mission, content)

          repo.transaction(
            fn ->
              with {:ok, updated_bank} <-
                     bank
                     |> Bank.changeset(%{mission: merged_mission, background: merged_mission})
                     |> repo.update(repo_opts),
                   response = %{
                     "mission" => updated_bank.mission || "",
                     "background" => updated_bank.background || updated_bank.mission || ""
                   },
                   {:ok, _audit_log} <-
                     insert_mutation_audit_log(
                       repo,
                       ctx,
                       "add_bank_background",
                       %{"content" => content},
                       response,
                       repo_opts,
                       started_at
                     ) do
                response
              else
                {:error, %Ecto.Changeset{} = changeset} ->
                  repo.rollback(
                    Error.new(:invalid_request, %{message: format_changeset(changeset)})
                  )

                {:error, %Error{} = error} ->
                  repo.rollback(error)
              end
            end,
            repo_opts
          )
          |> normalize_transaction_result()
      end
    end)
  end

  @impl true
  def delete_bank(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        bank ->
          repo.transaction(
            fn ->
              with {:ok, _deleted_bank} <- repo.delete(bank, repo_opts),
                   response = %{"id" => bank_id, "deleted" => true, "deleted_count" => 0},
                   {:ok, _audit_log} <-
                     insert_mutation_audit_log(
                       repo,
                       ctx,
                       "delete_bank",
                       %{"id" => bank_id},
                       response,
                       repo_opts,
                       started_at
                     ) do
                response
              else
                {:error, %Error{} = error} ->
                  repo.rollback(error)

                {:error, reason} ->
                  repo.rollback(Error.new(:invalid_request, %{message: inspect(reason)}))
              end
            end,
            repo_opts
          )
          |> normalize_transaction_result()
      end
    end)
  end

  @impl true
  def clear_bank_memories(ctx, bank_id, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      with {:ok, fact_type} <- normalize_clear_bank_type(Map.get(params, "type")),
           %Bank{} <-
             repo.get(Bank, bank_id, repo_opts) ||
               {:error, Error.new(:not_found, %{message: "bank not found"})} do
        memory_query =
          from(unit in MemoryUnit,
            where: unit.bank_id == ^bank_id
          )
          |> maybe_filter_clear_fact_type(fact_type)

        {:ok, response} =
          repo.transaction(
            fn ->
              {deleted_count, _} = repo.delete_all(memory_query, repo_opts)

              if is_nil(fact_type) do
                repo.delete_all(
                  from(link in EntityLink, where: link.bank_id == ^bank_id),
                  repo_opts
                )

                repo.delete_all(
                  from(entity in Entity, where: entity.bank_id == ^bank_id),
                  repo_opts
                )
              end

              response = %{"id" => bank_id, "deleted" => true, "deleted_count" => deleted_count}

              case insert_mutation_audit_log(
                     repo,
                     ctx,
                     "clear_bank_memories",
                     params,
                     response,
                     repo_opts,
                     started_at
                   ) do
                {:ok, _audit_log} -> response
                {:error, %Error{} = error} -> repo.rollback(error)
              end
            end,
            repo_opts
          )

        {:ok, response}
      else
        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def delete_memory(ctx, bank_id, memory_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      with {:ok, unit_id} <- cast_memory_id(memory_id),
           %MemoryUnit{} <- bank_memory_unit(repo, bank_id, unit_id, repo_opts) do
        transaction_result =
          with_deadlock_retry(fn ->
            repo.transaction(
              fn ->
                # Re-read inside the transaction: a concurrent delete (or a document
                # replace) may have removed the row since the check above.
                unit =
                  case bank_memory_unit(repo, bank_id, unit_id, repo_opts) do
                    %MemoryUnit{} = unit -> unit
                    nil -> repo.rollback(memory_not_found())
                  end

                # A source fact takes the observations consolidated from it along
                # (they would otherwise cite a unit that no longer exists) and sends
                # their other sources back to consolidation; an observation only
                # sends its sources back. Same contract as delete_document/4.
                {observation_ids, affected_source_ids} =
                  memory_delete_dependents(repo, bank_id, unit, repo_opts)

                retract_unit_entities(repo, bank_id, [unit.id | observation_ids], repo_opts)
                delete_observation_ids(repo, observation_ids, repo_opts)

                case repo.delete(unit, repo_opts) do
                  {:ok, _unit} ->
                    :ok

                  {:error, %Ecto.Changeset{} = changeset} ->
                    repo.rollback(
                      Error.new(:invalid_request, %{message: format_changeset(changeset)})
                    )
                end

                reset_source_units_for_reconsolidation(
                  repo,
                  affected_source_ids -- [unit.id],
                  repo_opts
                )

                response = %{
                  "success" => true,
                  "memory_id" => unit.id,
                  "memory_units_deleted" => 1 + length(observation_ids),
                  "observations_deleted" => length(observation_ids)
                }

                case insert_mutation_audit_log(
                       repo,
                       ctx,
                       "delete_memory",
                       %{"memory_id" => unit.id},
                       response,
                       repo_opts,
                       started_at
                     ) do
                  {:ok, _audit_log} -> response
                  {:error, %Error{} = error} -> repo.rollback(error)
                end
              end,
              repo_opts
            )
          end)

        case transaction_result do
          {:ok, response} -> {:ok, response}
          {:error, %Error{} = error} -> {:error, error}
        end
      else
        nil -> {:error, memory_not_found()}
        {:error, %Error{} = error} -> {:error, error}
      end
    end)
  end

  defp memory_not_found, do: Error.new(:not_found, %{message: "memory not found"})

  # memory_units.id is a UUID; a malformed id names nothing rather than raising a
  # cast error out of the query.
  defp cast_memory_id(memory_id) when is_binary(memory_id) do
    case Ecto.UUID.cast(memory_id) do
      {:ok, unit_id} -> {:ok, unit_id}
      :error -> {:error, memory_not_found()}
    end
  end

  defp bank_memory_unit(repo, bank_id, unit_id, repo_opts) do
    repo.one(
      from(unit in MemoryUnit, where: unit.bank_id == ^bank_id and unit.id == ^unit_id),
      repo_opts
    )
  end

  defp memory_delete_dependents(
         _repo,
         _bank_id,
         %MemoryUnit{fact_type: :observation} = unit,
         _repo_opts
       ) do
    {[], Enum.map(List.wrap(unit.source_memory_ids), &to_string/1)}
  end

  defp memory_delete_dependents(repo, bank_id, %MemoryUnit{} = unit, repo_opts) do
    affected_observation_ids(repo, bank_id, [unit.id], repo_opts)
  end

  @impl true
  def get_bank_config(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        %Bank{} = bank ->
          {:ok, bank_config_response(ctx, bank, runtime_config(opts))}
      end
    end)
  end

  @impl true
  def update_bank_config(ctx, bank_id, updates, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      runtime_cfg = runtime_config(opts)

      with {:ok, normalized_updates} <- normalize_bank_config_updates(updates),
           %Bank{} = bank <-
             repo.get(Bank, bank_id, repo_opts) ||
               {:error, Error.new(:not_found, %{message: "bank not found"})} do
        previous_overrides = bank.config_overrides || %{}
        updated_overrides = Resolver.apply_updates(previous_overrides, normalized_updates)

        repo.transaction(
          fn ->
            with {:ok, previous_profile} <-
                   effective_embedding_profile(ctx, previous_overrides, runtime_cfg, opts),
                 {:ok, next_profile} <-
                   effective_embedding_profile(ctx, updated_overrides, runtime_cfg, opts),
                 {:ok, updated_bank} <-
                   bank
                   |> Bank.changeset(%{config_overrides: updated_overrides})
                   |> repo.update(repo_opts),
                 :ok <-
                   maybe_enqueue_embedding_backfill(
                     ctx,
                     bank_id,
                     previous_profile,
                     next_profile,
                     opts
                   ) do
              bank_config_response(ctx, updated_bank, runtime_cfg)
            else
              {:error, %Ecto.Changeset{} = changeset} ->
                repo.rollback(
                  Error.new(:invalid_request, %{message: format_changeset(changeset)})
                )

              {:error, %Error{} = error} ->
                repo.rollback(error)
            end
          end,
          repo_opts
        )
        |> case do
          {:ok, response} -> {:ok, response}
          {:error, %Error{} = error} -> {:error, error}
        end
      else
        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def reset_bank_config(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      runtime_cfg = runtime_config(opts)

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        %Bank{} = bank ->
          previous_overrides = bank.config_overrides || %{}

          repo.transaction(
            fn ->
              with {:ok, previous_profile} <-
                     effective_embedding_profile(ctx, previous_overrides, runtime_cfg, opts),
                   {:ok, next_profile} <-
                     effective_embedding_profile(ctx, %{}, runtime_cfg, opts),
                   {:ok, updated_bank} <-
                     bank
                     |> Bank.changeset(%{config_overrides: %{}})
                     |> repo.update(repo_opts),
                   :ok <-
                     maybe_enqueue_embedding_backfill(
                       ctx,
                       bank_id,
                       previous_profile,
                       next_profile,
                       opts
                     ) do
                bank_config_response(ctx, updated_bank, runtime_cfg)
              else
                {:error, %Ecto.Changeset{} = changeset} ->
                  repo.rollback(
                    Error.new(:invalid_request, %{message: format_changeset(changeset)})
                  )

                {:error, %Error{} = error} ->
                  repo.rollback(error)
              end
            end,
            repo_opts
          )
          |> case do
            {:ok, response} -> {:ok, response}
            {:error, %Error{} = error} -> {:error, error}
          end
      end
    end)
  end

  @impl true
  def create_webhook(ctx, bank_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      with {:ok, normalized_attrs} <- normalize_create_webhook_attrs(bank_id, attrs) do
        repo.transaction(
          fn ->
            with {:ok, _bank} <- ensure_bank_exists(repo, bank_id, repo_opts),
                 {:ok, webhook} <-
                   %Webhook{}
                   |> Webhook.changeset(normalized_attrs)
                   |> repo.insert(repo_opts),
                 response = webhook_response(webhook),
                 {:ok, _audit_log} <-
                   insert_mutation_audit_log(
                     repo,
                     ctx,
                     "create_webhook",
                     normalized_attrs,
                     response,
                     repo_opts,
                     started_at
                   ) do
              response
            else
              {:error, %Ecto.Changeset{} = changeset} ->
                repo.rollback(
                  Error.new(:invalid_request, %{message: format_changeset(changeset)})
                )

              {:error, %Error{} = error} ->
                repo.rollback(error)
            end
          end,
          repo_opts
        )
        |> normalize_transaction_result()
      end
    end)
  end

  @impl true
  def list_webhooks(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      webhooks =
        from(webhook in Webhook,
          where: webhook.bank_id == ^bank_id,
          order_by: [asc: webhook.inserted_at]
        )
        |> repo.all(repo_opts)
        |> Enum.map(&webhook_response/1)

      {:ok, webhooks}
    end)
  end

  @impl true
  def update_webhook(ctx, bank_id, webhook_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      with {:ok, normalized_attrs} <- normalize_patch_webhook_attrs(attrs),
           %Webhook{} = webhook <-
             repo.one(
               from(webhook in Webhook,
                 where: webhook.id == ^webhook_id and webhook.bank_id == ^bank_id
               ),
               repo_opts
             ) || {:error, Error.new(:not_found, %{message: "Webhook not found"})} do
        repo.transaction(
          fn ->
            with {:ok, updated_webhook} <-
                   webhook
                   |> Webhook.changeset(normalized_attrs)
                   |> repo.update(repo_opts),
                 response = webhook_response(updated_webhook),
                 {:ok, _audit_log} <-
                   insert_mutation_audit_log(
                     repo,
                     ctx,
                     "update_webhook",
                     normalized_attrs,
                     response,
                     repo_opts,
                     started_at
                   ) do
              response
            else
              {:error, %Ecto.Changeset{} = changeset} ->
                repo.rollback(
                  Error.new(:invalid_request, %{message: format_changeset(changeset)})
                )

              {:error, %Error{} = error} ->
                repo.rollback(error)
            end
          end,
          repo_opts
        )
        |> normalize_transaction_result()
      else
        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def delete_webhook(ctx, bank_id, webhook_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case repo.one(
             from(webhook in Webhook,
               where: webhook.id == ^webhook_id and webhook.bank_id == ^bank_id
             ),
             repo_opts
           ) do
        nil ->
          {:error, Error.new(:not_found, %{message: "Webhook not found"})}

        %Webhook{} = webhook ->
          repo.transaction(
            fn ->
              with {:ok, _deleted_webhook} <- repo.delete(webhook, repo_opts),
                   response = %{"success" => true},
                   {:ok, _audit_log} <-
                     insert_mutation_audit_log(
                       repo,
                       ctx,
                       "delete_webhook",
                       %{"id" => webhook_id, "bank_id" => bank_id},
                       response,
                       repo_opts,
                       started_at
                     ) do
                response
              else
                {:error, %Ecto.Changeset{} = changeset} ->
                  repo.rollback(
                    Error.new(:invalid_request, %{message: format_changeset(changeset)})
                  )

                {:error, %Error{} = error} ->
                  repo.rollback(error)
              end
            end,
            repo_opts
          )
          |> normalize_transaction_result()
      end
    end)
  end

  @impl true
  def list_webhook_deliveries(ctx, bank_id, webhook_id, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = Map.get(params, "limit", 50)
      cursor = Map.get(params, "cursor")
      fetch_limit = limit + 1

      with %Webhook{} <-
             repo.one(
               from(webhook in Webhook,
                 where: webhook.id == ^webhook_id and webhook.bank_id == ^bank_id
               ),
               repo_opts
             ) || {:error, Error.new(:not_found, %{message: "Webhook not found"})} do
        deliveries =
          Delivery
          |> where(
            [delivery],
            delivery.bank_id == ^bank_id and delivery.webhook_id == ^webhook_id
          )
          |> maybe_filter_delivery_cursor(cursor)
          |> order_by([delivery], desc: delivery.inserted_at)
          |> limit(^fetch_limit)
          |> repo.all(repo_opts)

        has_more = length(deliveries) > limit
        page = Enum.take(deliveries, limit)

        {:ok,
         %{
           "items" => Enum.map(page, &delivery_response/1),
           "next_cursor" =>
             if(has_more and page != [],
               do: page |> List.last() |> Map.fetch!(:inserted_at) |> format_datetime(),
               else: nil
             )
         }}
      else
        {:error, %Error{} = error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def export_bank_template(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      with {:ok, %Bank{} = bank} <- fetch_bank(repo, bank_id, repo_opts) do
        {:ok,
         %{
           "version" => "1",
           "bank" => export_template_bank_config(bank.config_overrides || %{}),
           "mental_models" => export_template_mental_models(repo, bank_id, repo_opts),
           "directives" => export_template_directives(repo, bank_id, repo_opts)
         }}
      end
    end)
  end

  @impl true
  def import_bank_template(ctx, bank_id, manifest, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      with {:ok, normalized_manifest} <- normalize_template_manifest(manifest) do
        dry_run = Map.get(normalized_manifest, "dry_run", false)

        template_bank_config = Map.get(normalized_manifest, "bank")
        directives = List.wrap(normalized_manifest["directives"])
        mental_models = List.wrap(normalized_manifest["mental_models"])

        current_bank = repo.get(Bank, bank_id, repo_opts)

        existing_directives = template_directives_by_name(repo, bank_id, repo_opts)
        existing_mental_models = template_mental_models_by_id(repo, bank_id, repo_opts)

        response = %{
          "bank_id" => bank_id,
          "config_applied" => is_map(template_bank_config),
          "mental_models_created" =>
            mental_models
            |> Enum.map(& &1["id"])
            |> Enum.reject(&Map.has_key?(existing_mental_models, &1)),
          "mental_models_updated" =>
            mental_models
            |> Enum.map(& &1["id"])
            |> Enum.filter(&Map.has_key?(existing_mental_models, &1)),
          "directives_created" =>
            directives
            |> Enum.map(& &1["name"])
            |> Enum.reject(&Map.has_key?(existing_directives, &1)),
          "directives_updated" =>
            directives
            |> Enum.map(& &1["name"])
            |> Enum.filter(&Map.has_key?(existing_directives, &1)),
          "operation_ids" => [],
          "dry_run" => dry_run
        }

        if dry_run do
          {:ok, response}
        else
          Multi.new()
          |> Multi.run(:bank, fn repo, _changes ->
            upsert_template_bank(repo, current_bank, bank_id, template_bank_config, repo_opts)
          end)
          |> Multi.run(:directives, fn repo, _changes ->
            import_template_directives(repo, bank_id, directives, repo_opts)
          end)
          |> Multi.run(:mental_models, fn repo, _changes ->
            import_template_mental_models(repo, bank_id, mental_models, repo_opts)
          end)
          |> repo.transaction(repo_opts)
          |> case do
            {:ok, _changes} ->
              {:ok, response}

            {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
              {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}

            {:error, _step, %Error{} = error, _changes} ->
              {:error, error}
          end
        end
      end
    end)
  end

  @impl true
  def bank_stats(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      queue = Keyword.get(opts, :queue)

      total_nodes =
        repo.aggregate(
          from(unit in MemoryUnit, where: unit.bank_id == ^bank_id),
          :count,
          repo_opts
        )

      total_links =
        repo.aggregate(
          from(link in EntityLink, where: link.bank_id == ^bank_id),
          :count,
          repo_opts
        )

      total_documents =
        repo.aggregate(
          from(document in Document, where: document.bank_id == ^bank_id),
          :count,
          repo_opts
        )

      links_by_link_type =
        from(link in EntityLink,
          where: link.bank_id == ^bank_id,
          group_by: link.link_type,
          select: {link.link_type, count(link.id)}
        )
        |> repo.all(repo_opts)
        |> Map.new()

      nodes_by_fact_type =
        from(unit in MemoryUnit,
          where: unit.bank_id == ^bank_id,
          group_by: unit.fact_type,
          select: {unit.fact_type, count(unit.id)}
        )
        |> repo.all(repo_opts)
        |> Map.new(fn {fact_type, count} -> {Atom.to_string(fact_type), count} end)

      consolidation_state = bank_consolidation_state(repo, bank_id, repo_opts)
      last_consolidated_at = consolidation_state.last_consolidated_at

      total_observations = Map.get(nodes_by_fact_type, "observation", 0)
      operation_stats = bank_operation_stats(%{ctx | bank: bank_id}, queue, opts)

      failed_consolidation =
        from(unit in MemoryUnit,
          where:
            unit.bank_id == ^bank_id and not is_nil(unit.consolidation_failed_at) and
              unit.fact_type in [:experience, :world],
          select: count(unit.id)
        )
        |> repo.one(repo_opts)

      {:ok,
       %{
         "bank_id" => bank_id,
         "total_nodes" => total_nodes,
         "total_links" => total_links,
         "total_documents" => total_documents,
         "nodes_by_fact_type" => nodes_by_fact_type,
         "links_by_link_type" => links_by_link_type,
         "links_by_fact_type" => %{},
         "links_breakdown" => %{},
         "pending_operations" => Map.get(operation_stats, "pending_operations", 0),
         "failed_operations" => Map.get(operation_stats, "failed_operations", 0),
         "operations_by_status" => Map.get(operation_stats, "operations_by_status", %{}),
         "last_consolidated_at" => format_datetime(last_consolidated_at),
         "pending_consolidation" => consolidation_state.pending_consolidation,
         "failed_consolidation" => failed_consolidation || 0,
         "total_observations" => total_observations
       }}
    end)
  end

  @impl true
  def memories_timeseries(ctx, bank_id, period, time_field, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      config = memories_timeseries_config(period)
      normalized_time_field = normalize_memories_timeseries_time_field(time_field)
      window_start = DateTime.add(now(), -config.interval_seconds, :second)

      rows =
        bank_id
        |> memories_timeseries_query(normalized_time_field, config, window_start)
        |> repo.all(repo_opts)

      {:ok,
       %{
         "bank_id" => bank_id,
         "period" => config.period,
         "trunc" => config.trunc,
         "time_field" => normalized_time_field,
         "buckets" => build_memories_timeseries_buckets(rows, config)
       }}
    end)
  end

  @impl true
  def consolidate(ctx, payload, opts) when is_map(payload) do
    result =
      with_tenant_scope(ctx, Keyword.fetch!(opts, :repo), opts, fn ->
        Consolidation.consolidate(
          ctx,
          payload,
          opts,
          %{
            repo_opts: &tenant_repo_opts/1,
            fetch_bank: &fetch_bank/3,
            consolidation_groups: &consolidation_groups/4,
            pool_observations: &pool_observations/4,
            resolve_source_facts: &resolve_consolidation_source_facts/4,
            apply_prepared: &apply_prepared!/4,
            stamp_failed: &stamp_consolidation_failed!/3,
            lock_scope: &ConsolidationPersistence.lock_scope/4,
            pending_unit_ids: &ConsolidationPersistence.pending_unit_ids/3,
            refresh_mental_model: &refresh_mental_model!/6,
            audit_log: &insert_mutation_audit_log/7
          }
        )
      end)

    maybe_enqueue_consolidation_webhooks(result, ctx, opts)
  end

  @impl true
  def list_memories(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)

      filtered_query =
        from(unit in MemoryUnit, where: unit.bank_id == ^ctx.bank)
        |> maybe_filter_type(params["type"] || first_type(params["types"]))
        |> maybe_filter_query(params["q"])
        |> maybe_filter_tags(params["tags"])
        |> maybe_filter_tags_match(params["tags"], params["tags_match"])
        |> maybe_filter_after(params["after"])
        |> maybe_filter_before(params["before"])

      ordered_query =
        order_by(filtered_query, [unit], desc: unit.mentioned_at, desc: unit.inserted_at)

      if listing_post_filters?(params) do
        # scope_keys and min_score are derived from the mapped response rather than
        # from columns, so they cannot page in SQL: load the filtered bank, filter,
        # then slice. Both are Foresight extensions; a plain Hindsight listing never
        # takes this path.
        items =
          ordered_query
          |> repo.all(repo_opts)
          |> Enum.map(&memory_unit_to_response/1)
          |> maybe_filter_scope_keys(params["scope_keys"])
          |> maybe_filter_min_score(params["min_score"])

        {:ok,
         %{
           "items" => items |> Enum.drop(offset) |> Enum.take(limit),
           "total" => length(items),
           "limit" => limit,
           "offset" => offset
         }}
      else
        # Page in SQL: one COUNT plus one LIMIT/OFFSET read per page, instead of
        # loading every unit in the bank and slicing in memory (O(pages × rows)).
        total = repo.aggregate(filtered_query, :count, repo_opts)

        items =
          ordered_query
          |> limit(^limit)
          |> offset(^offset)
          |> repo.all(repo_opts)
          |> Enum.map(&memory_unit_to_response/1)

        {:ok, %{"items" => items, "total" => total, "limit" => limit, "offset" => offset}}
      end
    end)
  end

  defp listing_post_filters?(params) do
    present_scope_keys?(params["scope_keys"]) or is_number(params["min_score"])
  end

  defp present_scope_keys?(scope_keys) when is_list(scope_keys), do: scope_keys != []
  defp present_scope_keys?(_scope_keys), do: false

  @impl true
  def get_memory(ctx, memory_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(MemoryUnit, memory_id, repo_opts) do
        %MemoryUnit{bank_id: bank_id} = unit when bank_id == ctx.bank ->
          {:ok, memory_unit_detail(unit)}

        _ ->
          {:error, Error.new(:not_found, %{message: "memory not found"})}
      end
    end)
  end

  @impl true
  def get_memory_history(ctx, memory_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(MemoryUnit, memory_id, repo_opts) do
        %MemoryUnit{bank_id: bank_id, fact_type: :observation} = unit when bank_id == ctx.bank ->
          {:ok, normalize_observation_history(unit.metadata["history"])}

        %MemoryUnit{bank_id: bank_id} when bank_id == ctx.bank ->
          {:ok, []}

        _ ->
          {:error, Error.new(:not_found, %{message: "memory not found"})}
      end
    end)
  end

  @impl true
  def list_tags(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)

      case Map.get(params, "source", "memories") do
        source when source in [nil, "memories"] ->
          items =
            from(unit in MemoryUnit,
              where: unit.bank_id == ^ctx.bank,
              select: unit.tags
            )
            |> repo.all(repo_opts)
            |> List.flatten()
            |> Enum.frequencies()
            |> Enum.map(fn {tag, count} -> %{"tag" => tag, "count" => count} end)
            |> maybe_filter_tag_pattern(params["q"])
            |> Enum.sort_by(fn item -> {-item["count"], item["tag"]} end)

          total = length(items)

          {:ok,
           %{
             "items" => items |> Enum.drop(offset) |> Enum.take(limit),
             "total" => total,
             "limit" => limit,
             "offset" => offset
           }}

        unsupported ->
          {:error,
           Error.new(:invalid_request, %{
             message: "unsupported tags source: #{inspect(unsupported)}"
           })}
      end
    end)
  end

  defp bank_operation_stats(%Foresight.Context{} = ctx, queue, opts) when is_atom(queue) do
    if Code.ensure_loaded?(queue) and function_exported?(queue, :operation_counts, 2) do
      case queue.operation_counts(ctx, opts) do
        {:ok, stats} when is_map(stats) -> stats
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp bank_operation_stats(_ctx, _queue, _opts), do: %{}

  @impl true
  def list_entities(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)

      entities =
        from(entity in Entity,
          where: entity.bank_id == ^ctx.bank,
          order_by: [desc: entity.mention_count, asc: entity.canonical_name]
        )
        |> limit(^limit)
        |> offset(^offset)
        |> repo.all(repo_opts)

      {:ok,
       %{
         "items" => Enum.map(entities, &entity_to_response/1),
         "total" => entity_total(repo, ctx.bank, repo_opts),
         "limit" => limit,
         "offset" => offset
       }}
    end)
  end

  @impl true
  def entity_graph(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      min_count = normalize_min_count(params)

      edges =
        from(link in EntityLink,
          join: source in Entity,
          on: source.id == link.source_entity_id,
          join: target in Entity,
          on: target.id == link.target_entity_id,
          where:
            link.bank_id == ^ctx.bank and source.bank_id == ^ctx.bank and
              target.bank_id == ^ctx.bank and
              link.weight >= ^min_count,
          order_by: [desc: link.weight, desc: link.updated_at, asc: link.id],
          limit: ^limit,
          select: %{
            id: link.id,
            source_id: source.id,
            source_name: source.canonical_name,
            source_mentions: source.mention_count,
            target_id: target.id,
            target_name: target.canonical_name,
            target_mentions: target.mention_count,
            weight: link.weight,
            link_type: link.link_type,
            updated_at: link.updated_at
          }
        )
        |> repo.all(repo_opts)

      nodes =
        edges
        |> Enum.flat_map(fn edge ->
          [
            {edge.source_id, edge.source_name, edge.source_mentions},
            {edge.target_id, edge.target_name, edge.target_mentions}
          ]
        end)
        |> Enum.uniq_by(fn {id, _name, _mentions} -> id end)
        |> Enum.map(fn {id, name, mentions} ->
          %{
            "data" => %{
              "id" => id,
              "label" => name,
              "mentionCount" => mentions,
              "color" => entity_graph_node_color(mentions)
            }
          }
        end)

      {:ok,
       %{
         "nodes" => nodes,
         "edges" => Enum.map(edges, &entity_graph_edge/1),
         "total_entities" => length(nodes),
         "total_edges" => length(edges),
         "limit" => limit
       }}
    end)
  end

  @impl true
  def get_entity(ctx, entity_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(Entity, entity_id, repo_opts) do
        %Entity{bank_id: bank_id} = entity when bank_id == ctx.bank ->
          {:ok,
           %{
             "id" => entity.id,
             "canonical_name" => entity.canonical_name,
             "mention_count" => entity.mention_count,
             "first_seen" => format_datetime(entity.first_seen),
             "last_seen" => format_datetime(entity.last_seen),
             "metadata" => nil,
             "observations" => []
           }}

        _ ->
          {:error, Error.new(:not_found, %{message: "entity not found"})}
      end
    end)
  end

  @impl true
  def list_directives(ctx, bank_id, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)
      active_only = Map.get(params, "active_only", true)

      directives =
        from(directive in Directive,
          where: directive.bank_id == ^bank_id,
          order_by: [desc: directive.priority, asc: directive.name]
        )
        |> maybe_filter_active_directives(active_only)
        |> maybe_filter_tags(Map.get(params, "tags"))
        |> maybe_filter_tags_match(Map.get(params, "tags"), Map.get(params, "tags_match"))
        |> repo.all(repo_opts)

      {:ok,
       %{
         "items" =>
           directives
           |> Enum.drop(offset)
           |> Enum.take(limit)
           |> Enum.map(&directive_to_response/1),
         "total" => length(directives)
       }}
    end)
  end

  @impl true
  def get_directive(ctx, bank_id, directive_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(Directive, directive_id, repo_opts) do
        %Directive{bank_id: ^bank_id} = directive ->
          {:ok, directive_to_response(directive)}

        _ ->
          {:error, Error.new(:not_found, %{message: "directive not found"})}
      end
    end)
  end

  @impl true
  def create_directive(ctx, bank_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      with {:ok, _bank} <- ensure_bank_exists(repo, bank_id, repo_opts) do
        %Directive{}
        |> Directive.changeset(Map.put(attrs, "bank_id", bank_id))
        |> repo.insert(repo_opts)
        |> case do
          {:ok, directive} ->
            {:ok, directive_to_response(directive)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
        end
      end
    end)
  end

  @impl true
  def update_directive(ctx, bank_id, directive_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(Directive, directive_id, repo_opts) do
        %Directive{bank_id: ^bank_id} = directive ->
          directive
          |> Directive.changeset(attrs)
          |> repo.update(repo_opts)
          |> case do
            {:ok, updated} ->
              {:ok, directive_to_response(updated)}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
          end

        _ ->
          {:error, Error.new(:not_found, %{message: "directive not found"})}
      end
    end)
  end

  @impl true
  def delete_directive(ctx, bank_id, directive_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(Directive, directive_id, repo_opts) do
        %Directive{bank_id: ^bank_id} = directive ->
          case repo.delete(directive, repo_opts) do
            {:ok, _directive} ->
              {:ok, %{"deleted" => true}}

            {:error, %Ecto.Changeset{} = changeset} ->
              {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
          end

        _ ->
          {:error, Error.new(:not_found, %{message: "directive not found"})}
      end
    end)
  end

  @impl true
  def list_mental_models(ctx, bank_id, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)
      detail = Map.get(params, "detail", "full")

      documents =
        from(document in Document,
          where: document.bank_id == ^bank_id,
          where: fragment("?->>'document_type' = 'mental_model'", document.metadata),
          order_by: [asc: document.external_id]
        )
        |> maybe_filter_document_tags(Map.get(params, "tags"))
        |> maybe_filter_tags_match(Map.get(params, "tags"), Map.get(params, "tags_match"))
        |> repo.all(repo_opts)

      {:ok,
       %{
         "items" =>
           documents
           |> Enum.drop(offset)
           |> Enum.take(limit)
           |> Enum.map(
             &mental_model_to_response(
               &1,
               detail,
               mental_model_staleness(repo, bank_id, &1, repo_opts, detail)
             )
           ),
         "total" => length(documents)
       }}
    end)
  end

  @impl true
  def get_mental_model(ctx, bank_id, mental_model_id, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      detail = Map.get(params, "detail", "full")

      case bank_document_record(repo, bank_id, mental_model_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        %Document{} = document ->
          metadata = document.metadata || %{}

          if metadata["document_type"] == "mental_model" do
            staleness = Foresight.Reflect.MentalModels.stale?(repo, bank_id, document, repo_opts)
            {:ok, mental_model_to_response(document, detail, staleness)}
          else
            {:error, Error.new(:not_found, %{message: "mental model not found"})}
          end
      end
    end)
  end

  @impl true
  def get_mental_model_history(ctx, bank_id, mental_model_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case bank_document_record(repo, bank_id, mental_model_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        %Document{} = document ->
          metadata = document.metadata || %{}

          if metadata["document_type"] == "mental_model" do
            {:ok, normalize_mental_model_history(metadata["history"])}
          else
            {:error, Error.new(:not_found, %{message: "mental model not found"})}
          end
      end
    end)
  end

  @impl true
  def create_mental_model(ctx, bank_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)
    queue = Keyword.fetch!(opts, :queue)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      mental_model_id = attrs["id"] || generated_mental_model_id()

      with {:ok, _bank} <- ensure_bank_exists(repo, bank_id, repo_opts) do
        case bank_document_record(repo, bank_id, mental_model_id, repo_opts) do
          %Document{id: nil} ->
            create_mental_model_placeholder(
              repo,
              queue,
              ctx,
              bank_id,
              Map.put(attrs, "id", mental_model_id),
              opts,
              repo_opts
            )

          %Document{} ->
            {:error, Error.new(:invalid_request, %{message: "mental model id already exists"})}
        end
      end
    end)
  end

  @impl true
  def update_mental_model(ctx, bank_id, mental_model_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case bank_document_record(repo, bank_id, mental_model_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        %Document{} = document ->
          metadata = document.metadata || %{}

          if metadata["document_type"] == "mental_model" do
            document
            |> Document.changeset(
              mental_model_document_patch(document, attrs)
              |> maybe_put_mental_model_history_for_update(
                attrs,
                metadata,
                document.original_text
              )
            )
            |> repo.update(repo_opts)
            |> case do
              {:ok, updated} ->
                {:ok,
                 mental_model_to_response(
                   updated,
                   "full",
                   Foresight.Reflect.MentalModels.stale?(repo, bank_id, updated, repo_opts)
                 )}

              {:error, %Ecto.Changeset{} = changeset} ->
                {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
            end
          else
            {:error, Error.new(:not_found, %{message: "mental model not found"})}
          end
      end
    end)
  end

  @impl true
  def refresh_mental_model(ctx, bank_id, mental_model_id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    queue = Keyword.fetch!(opts, :queue)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case bank_document_record(repo, bank_id, mental_model_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        %Document{} = document ->
          metadata = document.metadata || %{}

          if metadata["document_type"] == "mental_model" do
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
          else
            {:error, Error.new(:not_found, %{message: "mental model not found"})}
          end
      end
    end)
  end

  @impl true
  def delete_mental_model(ctx, bank_id, mental_model_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case bank_document_record(repo, bank_id, mental_model_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        %Document{} = document ->
          metadata = document.metadata || %{}

          if metadata["document_type"] == "mental_model" do
            case repo.delete(document, repo_opts) do
              {:ok, _document} ->
                {:ok, %{"deleted" => true}}

              {:error, %Ecto.Changeset{} = changeset} ->
                {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
            end
          else
            {:error, Error.new(:not_found, %{message: "mental model not found"})}
          end
      end
    end)
  end

  @impl true
  def bank_profile(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(Bank, bank_id, repo_opts) do
        nil ->
          {:error, Error.new(:not_found, %{message: "bank not found"})}

        bank ->
          {:ok, bank_profile_response(bank)}
      end
    end)
  end

  @impl true
  def list_documents(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)

      filtered_query =
        from(document in Document, where: document.bank_id == ^ctx.bank)
        |> maybe_filter_document_query(params["q"])
        |> maybe_filter_document_tags(params["tags"])

      # Page in SQL (one COUNT, one LIMIT/OFFSET read) and count units only for
      # the documents on this page, instead of loading and counting the whole bank
      # for every page.
      total = repo.aggregate(filtered_query, :count, repo_opts)

      documents =
        filtered_query
        |> order_by([document], asc: document.external_id)
        |> limit(^limit)
        |> offset(^offset)
        |> repo.all(repo_opts)

      document_ids = Enum.map(documents, & &1.external_id)

      counts_by_document =
        from(unit in MemoryUnit,
          where: unit.bank_id == ^ctx.bank and unit.document_ref in ^document_ids,
          group_by: unit.document_ref,
          select: {unit.document_ref, count(unit.id)}
        )
        |> repo.all(repo_opts)
        |> Map.new()

      {:ok,
       %{
         "items" => Enum.map(documents, &document_to_response(&1, counts_by_document)),
         "total" => total,
         "limit" => limit,
         "offset" => offset
       }}
    end)
  end

  @impl true
  def get_document(ctx, document_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      document =
        from(document in Document,
          where: document.bank_id == ^ctx.bank and document.external_id == ^document_id
        )
        |> repo.one(repo_opts)

      case document do
        %Document{} = document ->
          counts_by_document =
            from(unit in MemoryUnit,
              where: unit.bank_id == ^ctx.bank and unit.document_ref == ^document.external_id,
              group_by: unit.fact_type,
              select: {unit.fact_type, count(unit.id)}
            )
            |> repo.all(repo_opts)
            |> Map.new(fn {fact_type, count} -> {Atom.to_string(fact_type), count} end)

          total_units = Enum.sum(Map.values(counts_by_document))

          {:ok,
           %{
             "id" => document.external_id,
             "bank_id" => document.bank_id,
             "original_text" => document.original_text || "",
             "content_hash" => document.content_hash,
             "created_at" => format_datetime(document.inserted_at),
             "updated_at" => format_datetime(document.updated_at),
             "memory_unit_count" => total_units,
             "nodes_by_fact_type" =>
               if(map_size(counts_by_document) == 0, do: nil, else: counts_by_document),
             "tags" => document.tags,
             "document_metadata" => document.metadata,
             "retain_params" => nil
           }}

        nil ->
          {:error, Error.new(:not_found, %{message: "document not found"})}
      end
    end)
  end

  @impl true
  def list_document_chunks(ctx, document_id, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)
      offset = normalize_offset(params)

      case bank_document_record(repo, ctx.bank, document_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "document not found"})}

        %Document{} ->
          units =
            from(unit in MemoryUnit,
              where: unit.bank_id == ^ctx.bank and unit.document_ref == ^document_id,
              order_by: [asc: unit.inserted_at, asc: unit.id]
            )
            |> repo.all(repo_opts)

          items =
            units
            |> Enum.with_index()
            |> Enum.map(fn {unit, index} ->
              %{
                "chunk_id" => unit.id,
                "document_id" => document_id,
                "bank_id" => ctx.bank,
                "chunk_index" => index,
                "chunk_text" => unit.content,
                "created_at" => format_datetime(unit.inserted_at)
              }
            end)

          {:ok,
           %{
             "items" => items |> Enum.drop(offset) |> Enum.take(limit),
             "total" => length(items),
             "limit" => limit,
             "offset" => offset
           }}
      end
    end)
  end

  @impl true
  def list_audit_logs(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = Map.get(params, "limit", 50)
      offset = normalize_offset(params)

      with {:ok, _bank} <- fetch_bank(repo, ctx.bank, repo_opts) do
        base_query =
          from(audit_log in AuditLog,
            where: audit_log.bank_id == ^ctx.bank
          )

        filtered_query =
          base_query
          |> maybe_filter_audit_action(params["action"])
          |> maybe_filter_audit_transport(params["transport"])
          |> maybe_filter_audit_started_at_gte(params["start_date"])
          |> maybe_filter_audit_started_at_lt(params["end_date"])

        total =
          filtered_query
          |> exclude(:order_by)
          |> repo.aggregate(:count, :id, repo_opts)

        items =
          filtered_query
          |> order_by([audit_log], desc: audit_log.started_at, desc: audit_log.id)
          |> limit(^limit)
          |> offset(^offset)
          |> repo.all(repo_opts)
          |> Enum.map(&audit_log_to_response/1)

        {:ok,
         %{
           "bank_id" => ctx.bank,
           "total" => total,
           "limit" => limit,
           "offset" => offset,
           "items" => items
         }}
      end
    end)
  end

  @impl true
  def audit_log_stats(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      period = Map.get(params, "period", "7d")
      start = audit_log_period_start(period)

      with {:ok, _bank} <- fetch_bank(repo, ctx.bank, repo_opts) do
        rows =
          from(audit_log in AuditLog,
            where: audit_log.bank_id == ^ctx.bank,
            where: audit_log.started_at >= ^start,
            group_by: [fragment("date_trunc('day', ?)", audit_log.started_at), audit_log.action],
            order_by: [asc: fragment("date_trunc('day', ?)", audit_log.started_at)],
            select: %{
              bucket:
                type(fragment("date_trunc('day', ?)", audit_log.started_at), :utc_datetime_usec),
              action: audit_log.action,
              count: count(audit_log.id)
            }
          )
          |> maybe_filter_audit_action(params["action"])
          |> repo.all(repo_opts)

        buckets =
          rows
          |> Enum.group_by(&format_datetime(&1.bucket))
          |> Enum.map(fn {time, bucket_rows} ->
            actions = Map.new(bucket_rows, fn row -> {row.action, row.count} end)

            %{
              "time" => time,
              "actions" => actions,
              "total" => Enum.reduce(bucket_rows, 0, &(&1.count + &2))
            }
          end)

        {:ok,
         %{
           "bank_id" => ctx.bank,
           "period" => period,
           "trunc" => "day",
           "start" => format_datetime(start),
           "buckets" => buckets
         }}
      end
    end)
  end

  @impl true
  def update_document(ctx, bank_id, document_id, attrs, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case bank_document_record(repo, bank_id, document_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "document not found"})}

        %Document{} ->
          transaction_result =
            with_deadlock_retry(fn ->
              repo.transaction(
                fn ->
                  lock_document(repo, bank_id, document_id, repo_opts)

                  # Re-read under the lock: a concurrent delete may have removed the row
                  # between the check above and here, and a concurrent replace may have
                  # rewritten it.
                  document =
                    case bank_document_record(repo, bank_id, document_id, repo_opts) do
                      %Document{id: nil} ->
                        repo.rollback(Error.new(:not_found, %{message: "document not found"}))

                      %Document{} = document ->
                        document
                    end

                  source_unit_ids =
                    document_source_unit_ids(repo, bank_id, document_id, repo_opts)

                  {observation_ids, affected_source_ids} =
                    affected_observation_ids(repo, bank_id, source_unit_ids, repo_opts)

                  document
                  |> Document.changeset(%{tags: List.wrap(attrs["tags"])})
                  |> repo.update(repo_opts)
                  |> case do
                    {:ok, _updated} ->
                      :ok

                    {:error, %Ecto.Changeset{} = changeset} ->
                      repo.rollback(
                        Error.new(:invalid_request, %{message: format_changeset(changeset)})
                      )
                  end

                  if source_unit_ids != [] do
                    from(unit in MemoryUnit, where: unit.id in ^source_unit_ids)
                    |> repo.update_all([set: [tags: List.wrap(attrs["tags"])]], repo_opts)
                  end

                  reset_source_units_for_reconsolidation(repo, affected_source_ids, repo_opts)
                  retract_unit_entities(repo, bank_id, observation_ids, repo_opts)
                  delete_observation_ids(repo, observation_ids, repo_opts)

                  response = %{"success" => true}

                  case insert_mutation_audit_log(
                         repo,
                         ctx,
                         "update_document",
                         %{"document_id" => document_id, "tags" => List.wrap(attrs["tags"])},
                         response,
                         repo_opts,
                         started_at
                       ) do
                    {:ok, _audit_log} -> response
                    {:error, %Error{} = error} -> repo.rollback(error)
                  end
                end,
                repo_opts
              )
            end)

          case transaction_result do
            {:ok, response} -> {:ok, response}
            {:error, %Error{} = error} -> {:error, error}
          end
      end
    end)
  end

  @impl true
  def delete_document(ctx, bank_id, document_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case bank_document_record(repo, bank_id, document_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "document not found"})}

        %Document{} ->
          transaction_result =
            with_deadlock_retry(fn ->
              repo.transaction(
                fn ->
                  lock_document(repo, bank_id, document_id, repo_opts)

                  # Re-read under the lock: a concurrent delete may have removed the row
                  # between the check above and here, and a concurrent replace may have
                  # rewritten it.
                  document =
                    case bank_document_record(repo, bank_id, document_id, repo_opts) do
                      %Document{id: nil} ->
                        repo.rollback(Error.new(:not_found, %{message: "document not found"}))

                      %Document{} = document ->
                        document
                    end

                  source_unit_ids =
                    document_source_unit_ids(repo, bank_id, document_id, repo_opts)

                  {observation_ids, affected_source_ids} =
                    affected_observation_ids(repo, bank_id, source_unit_ids, repo_opts)

                  retract_unit_entities(
                    repo,
                    bank_id,
                    source_unit_ids ++ observation_ids,
                    repo_opts
                  )

                  delete_observation_ids(repo, observation_ids, repo_opts)

                  {memory_units_deleted, _} =
                    from(unit in MemoryUnit,
                      where: unit.bank_id == ^bank_id and unit.document_ref == ^document_id
                    )
                    |> repo.delete_all(repo_opts)

                  reset_source_units_for_reconsolidation(
                    repo,
                    affected_source_ids |> Enum.reject(&(&1 in source_unit_ids)),
                    repo_opts
                  )

                  case repo.delete(document, repo_opts) do
                    {:ok, _document} ->
                      :ok

                    {:error, %Ecto.Changeset{} = changeset} ->
                      repo.rollback(
                        Error.new(:invalid_request, %{message: format_changeset(changeset)})
                      )
                  end

                  response = %{
                    "success" => true,
                    "message" =>
                      "Document '#{document_id}' and #{memory_units_deleted} associated memory units deleted successfully",
                    "document_id" => document_id,
                    "memory_units_deleted" => memory_units_deleted
                  }

                  case insert_mutation_audit_log(
                         repo,
                         ctx,
                         "delete_document",
                         %{"document_id" => document_id},
                         response,
                         repo_opts,
                         started_at
                       ) do
                    {:ok, _audit_log} -> response
                    {:error, %Error{} = error} -> repo.rollback(error)
                  end
                end,
                repo_opts
              )
            end)

          case transaction_result do
            {:ok, response} -> {:ok, response}
            {:error, %Error{} = error} -> {:error, error}
          end
      end
    end)
  end

  @impl true
  def reprocess_document(ctx, bank_id, document_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case bank_document_record(repo, bank_id, document_id, repo_opts) do
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "document not found"})}

        %Document{} = document ->
          original_text = document.original_text || ""

          if String.trim(original_text) == "" do
            {:error, Error.new(:not_found, %{message: "document not found"})}
          else
            payload = %{
              "items" => [
                %{
                  "content" => original_text,
                  "context" => "document",
                  "type" => "experience",
                  "document_id" => document.external_id,
                  "document_title" => document.title,
                  "document_text" => original_text,
                  "content_hash" => document.content_hash,
                  "file_storage_key" => document.file_storage_key,
                  "file_original_name" => document.file_original_name,
                  "file_content_type" => document.file_content_type,
                  "metadata" => document.metadata || %{},
                  "tags" => document.tags || [],
                  "update_mode" => "replace"
                }
              ],
              "async" => true
            }

            with {:ok, result} <- retain(ctx, payload, opts) do
              {:ok,
               %{
                 "success" => true,
                 "operation_id" => result["operation_id"],
                 "items_count" => result["items_count"] || 1
               }}
            end
          end
      end
    end)
  end

  @impl true
  def memory_graph(ctx, params, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      limit = normalize_limit(params)

      units =
        from(unit in MemoryUnit,
          where: unit.bank_id == ^ctx.bank,
          order_by: [desc: unit.mentioned_at, desc: unit.inserted_at]
        )
        |> maybe_filter_type(params["type"] || first_type(params["types"]))
        |> maybe_filter_query(params["q"])
        |> maybe_filter_tags(params["tags"])
        |> maybe_filter_tags_match(params["tags"], params["tags_match"])
        |> maybe_filter_document_id(params["document_id"])
        |> maybe_filter_chunk_id(params["chunk_id"])
        |> limit(^limit)
        |> repo.all(repo_opts)

      entity_names_by_unit = load_entity_names_by_unit(repo, Enum.map(units, & &1.id), repo_opts)

      table_rows =
        Enum.map(units, fn unit ->
          entity_names = Map.get(entity_names_by_unit, unit.id, [])
          memory_graph_table_row(unit, entity_names)
        end)

      {:ok,
       %{
         "nodes" =>
           Enum.map(units, &memory_graph_node(&1, Map.get(entity_names_by_unit, &1.id, []))),
         "edges" => memory_graph_edges(units, entity_names_by_unit),
         "table_rows" => table_rows,
         "total_units" => length(units),
         "limit" => limit
       }}
    end)
  end

  @impl true
  def get_chunk(ctx, chunk_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      case repo.get(MemoryUnit, chunk_id, repo_opts) do
        %MemoryUnit{bank_id: bank_id} = unit when bank_id == ctx.bank ->
          {:ok,
           %{
             "chunk_id" => unit.id,
             "document_id" => unit.document_ref,
             "bank_id" => ctx.bank,
             "chunk_index" => 0,
             "chunk_text" => unit.content,
             "created_at" => format_datetime(unit.inserted_at)
           }}

        _ ->
          {:error, Error.new(:not_found, %{message: "chunk not found"})}
      end
    end)
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
  def recover_consolidation(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      with %Bank{} <-
             repo.get(Bank, bank_id, repo_opts) ||
               {:error, Error.new(:not_found, %{message: "bank not found"})} do
        {:ok, response} =
          repo.transaction(
            fn ->
              {retried_count, _} =
                from(unit in MemoryUnit,
                  where:
                    unit.bank_id == ^bank_id and not is_nil(unit.consolidation_failed_at) and
                      unit.fact_type in [:experience, :world]
                )
                |> repo.update_all(
                  [set: [consolidated_at: nil, consolidation_failed_at: nil]],
                  repo_opts
                )

              response = %{"retried_count" => retried_count}

              case insert_mutation_audit_log(
                     repo,
                     ctx,
                     "recover_consolidation",
                     %{"bank_id" => bank_id},
                     response,
                     repo_opts,
                     started_at
                   ) do
                {:ok, _audit_log} -> response
                {:error, %Error{} = error} -> repo.rollback(error)
              end
            end,
            repo_opts
          )

        normalize_transaction_result({:ok, response})
      end
    end)
  end

  @impl true
  def clear_observations(ctx, bank_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      with %Bank{} <-
             repo.get(Bank, bank_id, repo_opts) ||
               {:error, Error.new(:not_found, %{message: "bank not found"})} do
        {:ok, response} =
          repo.transaction(
            fn ->
              observation_ids =
                from(unit in MemoryUnit,
                  where: unit.bank_id == ^bank_id and unit.fact_type == :observation,
                  select: unit.id
                )
                |> repo.all(repo_opts)

              retract_unit_entities(repo, bank_id, observation_ids, repo_opts)

              {deleted_count, _} =
                from(unit in MemoryUnit, where: unit.id in ^observation_ids)
                |> repo.delete_all(repo_opts)

              from(unit in MemoryUnit,
                where: unit.bank_id == ^bank_id and unit.fact_type in [:experience, :world]
              )
              |> repo.update_all([set: [consolidated_at: nil]], repo_opts)

              response = %{"deleted_count" => deleted_count}

              case insert_mutation_audit_log(
                     repo,
                     ctx,
                     "clear_observations",
                     %{"bank_id" => bank_id},
                     response,
                     repo_opts,
                     started_at
                   ) do
                {:ok, _audit_log} -> response
                {:error, %Error{} = error} -> repo.rollback(error)
              end
            end,
            repo_opts
          )

        {:ok, response}
      else
        {:error, %Error{} = error} -> {:error, error}
      end
    end)
  end

  @impl true
  def clear_memory_observations(ctx, bank_id, memory_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      started_at = now()

      case repo.get(MemoryUnit, memory_id, repo_opts) do
        %MemoryUnit{bank_id: ^bank_id} ->
          {:ok, response} =
            repo.transaction(
              fn ->
                {observation_ids, affected_source_ids} =
                  affected_observation_ids(repo, bank_id, [memory_id], repo_opts)

                retract_unit_entities(repo, bank_id, observation_ids, repo_opts)
                delete_observation_ids(repo, observation_ids, repo_opts)
                reset_source_units_for_reconsolidation(repo, affected_source_ids, repo_opts)

                response = %{"deleted_count" => length(observation_ids)}

                case insert_mutation_audit_log(
                       repo,
                       ctx,
                       "clear_memory_observations",
                       %{"bank_id" => bank_id, "memory_id" => memory_id},
                       response,
                       repo_opts,
                       started_at
                     ) do
                  {:ok, _audit_log} -> response
                  {:error, %Error{} = error} -> repo.rollback(error)
                end
              end,
              repo_opts
            )

          {:ok, response}

        _ ->
          {:error, Error.new(:not_found, %{message: "memory not found"})}
      end
    end)
  end

  def refresh_mental_model_operation(ctx, payload, opts) do
    repo = Keyword.fetch!(opts, :repo)
    bank_id = Map.get(payload, "bank_id", ctx.bank)
    mental_model_id = Map.get(payload, "mental_model_id")

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)

      with mental_model_id when is_binary(mental_model_id) and mental_model_id != "" <-
             mental_model_id,
           %Document{} = document <-
             bank_document_record(repo, bank_id, mental_model_id, repo_opts),
           metadata when is_map(metadata) <- document.metadata || %{},
           "mental_model" <- metadata["document_type"],
           source_query when is_binary(source_query) and source_query != "" <-
             metadata["source_query"],
           {:ok, reflect_result} <-
             reflect(
               ctx,
               Map.merge(Map.get(metadata, "trigger", %{}), %{
                 "query" => source_query,
                 "tags" => document.tags || [],
                 "max_tokens" => Map.get(metadata, "max_tokens", 2048),
                 "exclude_mental_model_ids" => [mental_model_id]
               }),
               opts
             ) do
        refreshed_at = format_datetime(now())

        history =
          maybe_record_mental_model_history(
            metadata,
            document.original_text,
            metadata["reflect_response"]
          )

        updated_attrs =
          mental_model_document_patch(document, %{})
          |> Map.put(:original_text, reflect_result["text"] || document.original_text)
          |> Map.put(
            :metadata,
            metadata
            |> Map.put("document_type", "mental_model")
            |> Map.put("reflect_response", reflect_result)
            |> Map.put("last_refreshed_at", refreshed_at)
            |> Map.put("is_stale", false)
            |> maybe_put_history(history)
          )

        document
        |> Document.changeset(updated_attrs)
        |> repo.update(repo_opts)
        |> case do
          {:ok, updated} ->
            # Index the fresh content now so the next reflect ranks it semantically
            # without a lazy re-embed on its hot path.
            case reflect_embedding_profile(repo, ctx, repo_opts, opts) do
              nil ->
                :ok

              profile ->
                Foresight.Reflect.MentalModels.ensure_embeddings(
                  repo,
                  bank_id,
                  [updated],
                  profile,
                  Keyword.fetch!(opts, :embedder),
                  repo_opts
                )
            end

            {:ok,
             %{
               "operation" => "refresh_mental_model",
               "bank_id" => bank_id,
               "mental_model_id" => mental_model_id,
               "content_updated" => true,
               "last_refreshed_at" => refreshed_at
             }}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
        end
      else
        %Document{id: nil} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        %Document{} ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}

        nil ->
          {:error, Error.new(:invalid_request, %{message: "mental_model_id is required"})}

        "" ->
          {:error, Error.new(:invalid_request, %{message: "mental_model_id is required"})}

        {:error, %Error{} = error} ->
          {:error, error}

        _other ->
          {:error, Error.new(:not_found, %{message: "mental model not found"})}
      end
    end)
  end

  def backfill_embeddings(ctx, payload, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_tenant_scope(ctx, repo, opts, fn ->
      repo_opts = tenant_repo_opts(ctx)
      embedder = Keyword.fetch!(opts, :embedder)
      runtime_cfg = Keyword.get(opts, :runtime_config, runtime_config(opts))
      bank_id = Map.get(payload, "bank_id", ctx.bank)

      with {:ok, profile} <- payload_embedding_profile(payload, runtime_cfg, opts) do
        stale_units =
          from(unit in MemoryUnit, where: unit.bank_id == ^bank_id)
          |> repo.all(repo_opts)
          |> Enum.filter(&EmbeddingProfile.stale?(&1, profile))

        {updated_count, failed_ids} =
          Enum.reduce(stale_units, {0, []}, fn unit, {updated_count, failed_ids} ->
            case embedder.embed(unit.content, EmbeddingProfile.embedder_opts(profile)) do
              {:ok, embedding} ->
                attrs =
                  %{
                    embedded_by: profile["model_id"],
                    embedded_dim: profile["embedding_dim"]
                  }
                  |> Map.merge(vector_attrs(profile, embedding))

                case unit |> MemoryUnit.changeset(attrs) |> repo.update(repo_opts) do
                  {:ok, _updated_unit} -> {updated_count + 1, failed_ids}
                  {:error, _changeset} -> {updated_count, [unit.id | failed_ids]}
                end

              {:error, _reason} ->
                {updated_count, [unit.id | failed_ids]}
            end
          end)

        if failed_ids == [] do
          {:ok,
           %{
             "bank_id" => bank_id,
             "updated_count" => updated_count,
             "target_profile" => profile
           }}
        else
          {:error,
           Error.new(:unavailable, %{
             message: "embedding backfill failed for one or more memory units",
             bank_id: bank_id,
             failed_ids: Enum.reverse(failed_ids),
             target_profile: profile
           })}
        end
      end
    end)
  end

  defp prepare_memory_unit_attrs(bank_id, items, embedder, profile) do
    with {:ok, embeddings} <- embed_retain_contents(items, embedder, profile) do
      items
      |> Enum.zip(embeddings)
      |> Enum.reduce_while({:ok, []}, fn {item, embedding}, {:ok, prepared} ->
        case build_memory_unit_attrs(bank_id, item, profile, embedding) do
          {:ok, attrs} -> {:cont, {:ok, [attrs | prepared]}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp insert_prepared_memory_units(repo, prepared_memory_units, repo_opts) do
    Enum.reduce_while(prepared_memory_units, {:ok, []}, fn attrs, {:ok, inserted} ->
      with changeset <- MemoryUnit.changeset(%MemoryUnit{}, attrs),
           {:ok, memory_unit} <- repo.insert(changeset, repo_opts) do
        {:cont, {:ok, [memory_unit | inserted]}}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, Enum.reverse(inserted)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp build_memory_unit_attrs(
         bank_id,
         %{"content" => content, "context" => context} = item,
         profile,
         embedding
       )
       when is_binary(content) and is_binary(context) do
    {:ok,
     %{
       bank_id: bank_id,
       fact_type: normalize_fact_type(item["type"] || get_in(item, ["metadata", "fact_type"])),
       content: content,
       context: context,
       tags: List.wrap(item["tags"]),
       metadata: Map.get(item, "metadata", %{}),
       document_ref: document_ref(item),
       source_location: retain_source_location(item),
       proof_count: Map.get(item, "proof_count", 1),
       source_memory_ids: normalize_source_memory_ids(item),
       embedded_by: profile["model_id"],
       embedded_dim: profile["embedding_dim"],
       occurred_at: parse_datetime(item["occurred_at"]),
       occurred_start: parse_datetime(item["occurred_start"] || item["occurred_at"]),
       occurred_end: parse_datetime(item["occurred_end"] || item["occurred_at"]),
       mentioned_at: parse_datetime(item["mentioned_at"]) || DateTime.utc_now(),
       observation_scopes: ConsolidationPersistence.normalize_observation_scopes(item)
     }
     |> Map.merge(vector_attrs(profile, embedding))}
  end

  defp build_memory_unit_attrs(_bank_id, _item, _profile, _embedding) do
    {:error,
     Error.new(:invalid_request, %{
       message: "each retain item must include string content and context"
     })}
  end

  defp embed_retain_contents(items, embedder, profile) do
    contents = Enum.map(items, &Map.fetch!(&1, "content"))
    opts = EmbeddingProfile.embedder_opts(profile)

    cond do
      function_exported?(embedder, :embed_many, 2) ->
        with {:ok, embeddings} <- embedder.embed_many(contents, opts),
             :ok <- ensure_embedding_count(contents, embeddings) do
          {:ok, embeddings}
        end

      true ->
        items
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, embeddings} ->
          case embedder.embed(item["content"], opts) do
            {:ok, embedding} -> {:cont, {:ok, [embedding | embeddings]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
          {:error, reason} -> {:error, reason}
        end
    end
    |> normalize_embedding_result()
  end

  defp ensure_embedding_count(contents, embeddings) when length(contents) == length(embeddings),
    do: :ok

  defp ensure_embedding_count(contents, embeddings) do
    {:error,
     Error.new(:internal, %{
       message:
         "embedder returned #{length(embeddings)} embeddings for #{length(contents)} retain items"
     })}
  end

  defp normalize_embedding_result({:ok, embeddings}), do: {:ok, embeddings}
  defp normalize_embedding_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_embedding_result({:error, reason}),
    do: {:error, Error.new(:internal, %{message: to_string(reason)})}

  defp extract_retain_items(items) do
    items
    |> Enum.flat_map(&extract_retain_item/1)
  end

  # Caps on the free-form JSON a retain item may carry. Both land in JSONB columns
  # and come back on every read of the memory, so unbounded input is the same class
  # of problem as unbounded content. Checked before extraction, on the raw items.
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

  # Options passed to atomic-fact extraction. `:retain_extraction_mode`
  # is nil by default → passthrough; the engine (or an eval) opts in explicitly.
  # The extraction LLM is the engine `:llm` handle, same as consolidation/reflect.
  defp retain_extraction_opts(opts) do
    # Reject nil values: LlmCore reads provider/provider_opts from the engine
    # config and merges passed opts on top, so a nil provider_opts here would
    # crash its Keyword.merge. Omitting the key lets the engine config supply it.
    [
      mode: Keyword.get(opts, :retain_extraction_mode),
      llm: Keyword.get(opts, :llm),
      mission: Keyword.get(opts, :retain_extraction_mission),
      custom_instructions: Keyword.get(opts, :retain_extraction_instructions),
      deadline_ms: Keyword.get(opts, :retain_extraction_deadline_ms),
      max_concurrency: Keyword.get(opts, :retain_extraction_concurrency),
      provider: Keyword.get(opts, :provider),
      # Extraction may use a different model than the reader/reflect LLM (it needs
      # clean structured-JSON output, which not every tool-calling model gives).
      # An explicit override wins; otherwise fall back to the engine provider_opts.
      provider_opts:
        Keyword.get(opts, :retain_extraction_provider_opts) ||
          Keyword.get(opts, :provider_opts)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
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

  defp ensure_nonempty_retain_extraction([]) do
    {:error,
     Error.new(:invalid_request, %{
       message: "retain extracted zero facts from payload"
     })}
  end

  defp ensure_nonempty_retain_extraction(_items), do: :ok

  # Columns a re-retain of an existing document_id overwrites. The id and inserted_at
  # of the original row are kept.
  @document_upsert_fields [
    :title,
    :original_text,
    :content_hash,
    :file_storage_key,
    :file_original_name,
    :file_content_type,
    :tags,
    :metadata,
    :updated_at
  ]

  defp upsert_documents(repo, bank_id, items, repo_opts) do
    items
    |> Enum.map(&document_attrs(bank_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.external_id)
    # Row locks are taken one document at a time; a stable order means two batches
    # naming the same documents in different orders cannot deadlock on them.
    |> Enum.sort_by(& &1.external_id)
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, documents} ->
      # One INSERT ... ON CONFLICT DO UPDATE. The former read-then-write pair raced
      # itself when two retains introduced the same document_id at once, and the
      # unique index turned the loser into a raised Ecto.ConstraintError.
      changeset = Document.changeset(%Document{}, attrs)

      insert_opts =
        Keyword.merge(repo_opts,
          on_conflict: {:replace, @document_upsert_fields},
          conflict_target: [:bank_id, :external_id],
          returning: true
        )

      case repo.insert(changeset, insert_opts) do
        {:ok, document} ->
          {:cont, {:ok, [document | documents]}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp replace_document_memory_units(repo, bank_id, items, repo_opts) do
    # The advisory locks were taken in the :document_locks step, before the document
    # rows were upserted, so this step only has to do the work.
    replace_document_ids = replace_document_ids(items)

    Enum.each(replace_document_ids, fn document_id ->
      source_unit_ids = document_source_unit_ids(repo, bank_id, document_id, repo_opts)

      {observation_ids, affected_source_ids} =
        affected_observation_ids(repo, bank_id, source_unit_ids, repo_opts)

      retract_unit_entities(repo, bank_id, source_unit_ids ++ observation_ids, repo_opts)
      delete_observation_ids(repo, observation_ids, repo_opts)

      from(unit in MemoryUnit,
        where: unit.bank_id == ^bank_id and unit.document_ref == ^document_id
      )
      |> repo.delete_all(repo_opts)

      # Siblings that fed a deleted observation are released so consolidation can form
      # a fresh one — the same release delete_documents performs.
      reset_source_units_for_reconsolidation(
        repo,
        Enum.reject(affected_source_ids, &(&1 in source_unit_ids)),
        repo_opts
      )
    end)

    {:ok, %{document_ids: replace_document_ids}}
  end

  # Documents a retain batch replaces, sorted so two requests replacing the same set
  # take their locks in the same order and cannot deadlock.
  defp replace_document_ids(items) do
    items
    |> Enum.filter(&(Map.get(&1, "update_mode") == "replace"))
    |> Enum.map(&document_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lock_replace_documents(repo, bank_id, items, repo_opts) do
    document_ids = replace_document_ids(items)
    Enum.each(document_ids, &lock_document(repo, bank_id, &1, repo_opts))
    {:ok, document_ids}
  end

  # Serialise the writers that delete a document's memory units: retain in replace
  # mode, delete_document and update_document. Every one of them takes this lock
  # before touching the document row or its units, so the lock order is always
  # advisory lock -> document row -> memory units and no pair can deadlock. The
  # transaction-scoped lock is released at commit or rollback, so an overlapping
  # request waits, then sees the first request's committed units and works on those.
  # Keys are hashes of the bank and document ids; a hash collision across tenants
  # only serialises two unrelated writers.
  # Postgres resolves a lock cycle by aborting one side with deadlock_detected. The
  # writers above are serialised per document by the advisory lock, but post-commit
  # link construction inserts memory_links that reference neighbouring units, and
  # that can still cross a concurrent replace or delete of those neighbours. The
  # aborted transaction has done nothing, so retrying it is safe; the jitter lets
  # the other side finish first.
  @deadlock_attempts 4

  defp with_deadlock_retry(fun, attempt \\ 1) do
    fun.()
  rescue
    error in [Postgrex.Error] ->
      if deadlock?(error) and attempt < @deadlock_attempts do
        Process.sleep(10 * attempt + :rand.uniform(20))
        with_deadlock_retry(fun, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp deadlock?(%{postgres: %{code: :deadlock_detected}}), do: true
  defp deadlock?(_error), do: false

  defp lock_document(repo, bank_id, document_id, repo_opts) do
    repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [bank_id, document_id],
      repo_opts
    )

    :ok
  end

  defp document_source_unit_ids(repo, bank_id, document_id, repo_opts) do
    from(unit in MemoryUnit,
      where: unit.bank_id == ^bank_id and unit.document_ref == ^document_id,
      select: unit.id
    )
    |> repo.all(repo_opts)
  end

  defp affected_observation_ids(_repo, _bank_id, [], _repo_opts), do: {[], []}

  defp affected_observation_ids(repo, bank_id, source_unit_ids, repo_opts) do
    observations =
      from(unit in MemoryUnit,
        where:
          unit.bank_id == ^bank_id and unit.fact_type == :observation and
            fragment(
              "? && ?::uuid[]",
              unit.source_memory_ids,
              type(^source_unit_ids, {:array, Ecto.UUID})
            ),
        select: {unit.id, unit.source_memory_ids}
      )
      |> repo.all(repo_opts)

    observation_ids = Enum.map(observations, &elem(&1, 0))

    affected_source_ids =
      observations
      |> Enum.flat_map(fn {_id, ids} -> List.wrap(ids) end)
      |> Enum.uniq()

    {observation_ids, Enum.uniq(source_unit_ids ++ affected_source_ids)}
  end

  defp delete_observation_ids(_repo, [], _repo_opts), do: :ok

  defp delete_observation_ids(repo, observation_ids, repo_opts) do
    from(unit in MemoryUnit, where: unit.id in ^observation_ids)
    |> repo.delete_all(repo_opts)

    :ok
  end

  defp reset_source_units_for_reconsolidation(_repo, [], _repo_opts), do: :ok

  defp reset_source_units_for_reconsolidation(repo, source_ids, repo_opts) do
    from(unit in MemoryUnit,
      where: unit.id in ^source_ids and unit.fact_type in [:experience, :world]
    )
    |> repo.update_all([set: [consolidated_at: nil, consolidation_failed_at: nil]], repo_opts)

    :ok
  end

  # Scoped inverse of materialize_entities/8 for memory units that are about to be
  # deleted: undo their mention counts and co-occurrence weights, drop the links that
  # fall to zero, and prune the entities no surviving unit mentions. Entities the
  # survivors still mention keep their identity, type, and name embedding.
  #
  # This replaced a whole-bank rebuild that deleted every entity and link in the bank
  # and re-derived them from stored content with the regex extractor: O(bank) per
  # call, and it discarded LLM-extracted entities and their name embeddings for good.
  # first_seen/last_seen are not recomputed; they only feed the resolver's recency
  # signal, where a stale value slightly overweights one candidate.
  defp retract_unit_entities(_repo, _bank_id, [], _repo_opts), do: :ok

  defp retract_unit_entities(repo, bank_id, unit_ids, repo_opts) do
    links =
      from(link in MemoryUnitEntity,
        where: link.memory_unit_id in ^unit_ids,
        select: {link.memory_unit_id, link.entity_id}
      )
      |> repo.all(repo_opts)

    if links == [] do
      :ok
    else
      entity_ids = links |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      links
      |> Enum.frequencies_by(&elem(&1, 1))
      |> Enum.each(fn {entity_id, mentions} ->
        from(entity in Entity,
          where: entity.id == ^entity_id,
          update: [
            set: [
              mention_count: fragment("GREATEST(? - ?, 0)", entity.mention_count, ^mentions)
            ]
          ]
        )
        |> repo.update_all([], repo_opts)
      end)

      # Each unit bumped the weight of every pair of its entities by one
      # (upsert_entity_links/4); take those bumps back and drop exhausted links.
      links
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {_unit_id, ids} -> canonical_pairs(ids) end)
      |> Enum.frequencies()
      |> Enum.each(fn {{source_id, target_id}, weight} ->
        from(link in EntityLink,
          where:
            link.bank_id == ^bank_id and link.source_entity_id == ^source_id and
              link.target_entity_id == ^target_id and link.link_type == "co_occurrence",
          update: [set: [weight: fragment("? - ?", link.weight, ^weight)]]
        )
        |> repo.update_all([], repo_opts)
      end)

      repo.delete_all(
        from(link in EntityLink, where: link.bank_id == ^bank_id and link.weight <= 0),
        repo_opts
      )

      repo.delete_all(
        from(link in MemoryUnitEntity, where: link.memory_unit_id in ^unit_ids),
        repo_opts
      )

      # Entities no surviving unit mentions; their remaining links and name embedding
      # go with them by cascade.
      from(entity in Entity,
        as: :entity,
        where:
          entity.bank_id == ^bank_id and entity.id in ^entity_ids and
            not exists(
              from(link in MemoryUnitEntity,
                where: link.entity_id == parent_as(:entity).id,
                select: 1
              )
            )
      )
      |> repo.delete_all(repo_opts)

      :ok
    end
  end

  defp upsert_file_storage(repo, items, repo_opts) do
    with {:ok, attrs_list} <- build_file_storage_attrs(items) do
      attrs_list
      |> Enum.uniq_by(& &1.storage_key)
      |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, rows} ->
        changeset =
          (repo.get(FileStorage, attrs.storage_key, repo_opts) || %FileStorage{})
          |> FileStorage.changeset(attrs)

        case repo.insert_or_update(changeset, repo_opts) do
          {:ok, row} ->
            {:cont, {:ok, [row | rows]}}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:halt,
             {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp build_file_storage_attrs(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case file_storage_attrs(item) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp file_storage_attrs(%{"file_storage_key" => storage_key, "file_storage_data" => data})
       when is_binary(storage_key) and is_binary(data),
       do: {:ok, %{storage_key: storage_key, data: data}}

  defp file_storage_attrs(%{"file_storage_data" => _data}) do
    {:error,
     Error.new(:invalid_request, %{
       message: "file storage key is required when file data is present"
     })}
  end

  defp file_storage_attrs(_item), do: {:ok, nil}

  # The entity extractor is a seam (engine `:entity_extractor`, default the regex
  # `Simple`). It is a FALLBACK: when an item carries LLM-extracted `entities`
  # (fact extraction, threaded via fact_to_item), those are used directly —
  # matching Hindsight's `fact.entities` source (entity_processing.py:32) — and the
  # extractor is not consulted.
  defp entity_extractor(opts),
    do: Keyword.get(opts, :entity_extractor, Foresight.EntityExtractors.Simple)

  # The subset of retain opts an extractor's optional `extract/2` may need (the LLM
  # extractor needs the `:llm` handle + provider hints). Passed through to
  # `EntityExtractor.run/3`; ignored by the pure `Simple.extract/1`.
  defp extractor_opts(opts),
    do: Keyword.take(opts, [:llm, :provider, :provider_opts, :sleep_ms])

  @default_entity_type "CONCEPT"

  # Prefer the item's LLM-extracted entities as {name, type} specs; fall back to the
  # extractor over the content only when the item carries none. An explicit empty list
  # is respected (the LLM found no entities — do not backfill regex noise), mirroring
  # Hindsight's `fact.entities or []`. Untyped entities default to CONCEPT — the type
  # Hindsight hardcodes for all of them (typed extraction carries real types when present).
  defp item_entity_specs(%{"entities" => entities}, _extractor, _extractor_opts)
       when is_list(entities) do
    entities
    |> Enum.map(&entity_spec/1)
    |> Enum.reject(&(&1.name == ""))
    |> Enum.uniq_by(& &1.name)
  end

  defp item_entity_specs(item, extractor, extractor_opts) do
    item["content"]
    |> to_string()
    |> then(&EntityExtractor.run(extractor, &1, extractor_opts))
    |> Enum.map(&%{name: &1, type: @default_entity_type})
  end

  defp entity_spec(name) when is_binary(name),
    do: %{name: String.trim(name), type: @default_entity_type}

  defp entity_spec(%{"name" => name, "type" => type}) when is_binary(name),
    do: %{name: String.trim(name), type: normalize_entity_type(type)}

  defp entity_spec(%{"name" => name}) when is_binary(name),
    do: %{name: String.trim(name), type: @default_entity_type}

  defp entity_spec(%{"text" => text}) when is_binary(text),
    do: %{name: String.trim(text), type: @default_entity_type}

  defp entity_spec(_other), do: %{name: "", type: @default_entity_type}

  defp normalize_entity_type(type) do
    case type |> to_string() |> String.trim() do
      "" -> @default_entity_type
      trimmed -> String.upcase(trimmed)
    end
  end

  defp materialize_entities(
         repo,
         bank_id,
         inserted_pairs,
         extractor,
         extractor_opts,
         embedder,
         profile,
         repo_opts
       ) do
    # Freeze fuzzy-resolution candidates to the bank state BEFORE this retain creates
    # any entity — faithful to Hindsight loading candidates once per batch, so two new
    # entities in the same retain (e.g. "Spanish course" and "pottery course") never
    # fuzzy-merge into each other. Exact-name dedup still runs live per item, so a name
    # repeated across items collapses to one entity.
    res_ctx = build_resolution_context(repo, bank_id, embedder, profile, repo_opts)

    Enum.reduce_while(inserted_pairs, {:ok, []}, fn {memory_unit, item}, {:ok, acc} ->
      entity_specs = item_entity_specs(item, extractor, extractor_opts)

      with {:ok, entity_ids} <-
             upsert_entities(
               repo,
               bank_id,
               entity_specs,
               memory_unit.mentioned_at,
               res_ctx,
               repo_opts
             ),
           {:ok, _} <- link_memory_unit_entities(repo, memory_unit.id, entity_ids, repo_opts),
           {:ok, _} <- upsert_entity_links(repo, bank_id, entity_ids, repo_opts) do
        {:cont, {:ok, [entity_ids | acc]}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # Batch-start snapshot the resolver scores against: strategy, the pre-existing
  # entity set (frozen so same-batch creations are not fuzzy candidates), the
  # co-occurrence index as it stood before this retain, and the semantic-recall
  # config (off unless explicitly enabled AND an embedder + profile are present).
  defp build_resolution_context(repo, bank_id, embedder, profile, repo_opts) do
    bank_entities = load_bank_entities(repo, bank_id, repo_opts)

    %{
      trigram?: use_trigram_lookup?(repo, repo_opts),
      prebatch_ids: MapSet.new(bank_entities, & &1.id),
      bank_entities: bank_entities,
      cooccurrence: build_cooccurrence_index(repo, bank_id, repo_opts),
      semantic?: semantic_recall_enabled?() and not is_nil(embedder) and is_map(profile),
      embedder: embedder,
      profile: profile
    }
  end

  # Resolve each mention to an entity id, faithful to Hindsight's entity_resolver:
  #
  #   1. Exact normalized-name match → merge (the unique (bank_id, normalized_name)
  #      index makes this deterministic, mirroring Hindsight's ON CONFLICT dedup).
  #   2. Otherwise gather fuzzy candidates — pg_trgm trigram similarity when the
  #      extension is present, else the substring "full" fallback — and hand them to
  #      the 3-signal scorer (name × 0.5 + co-occurrence × 0.3 + recency × 0.2). Merge
  #      the best candidate iff its score clears 0.6, else create a new entity.
  #
  # `entity_specs` are %{name, type}. `nearby` for the co-occurrence signal is the
  # other entity names in this same item. `res_ctx` is the batch-start snapshot from
  # build_resolution_context/5.
  defp upsert_entities(repo, bank_id, entity_specs, mentioned_at, res_ctx, repo_opts) do
    names = Enum.map(entity_specs, & &1.name)

    entity_ids =
      Enum.map(entity_specs, fn %{name: name, type: type} ->
        normalized_name = normalize_entity_name(name)

        case repo.get_by(Entity, [bank_id: bank_id, normalized_name: normalized_name], repo_opts) do
          %Entity{} = existing ->
            bump_entity!(repo, existing, mentioned_at, repo_opts)

          nil ->
            nearby = Enum.reject(names, &(&1 == name))
            candidates = scorer_candidates(repo, bank_id, name, res_ctx, repo_opts)

            case Resolution.resolve(name, candidates, nearby: nearby, event_date: mentioned_at) do
              {:merge, id} ->
                bump_entity!(repo, repo.get(Entity, id, repo_opts), mentioned_at, repo_opts)

              :create ->
                create_entity!(
                  repo,
                  bank_id,
                  name,
                  normalized_name,
                  type,
                  mentioned_at,
                  res_ctx,
                  repo_opts
                )
            end
        end
      end)

    {:ok, entity_ids}
  catch
    {:entity_error, changeset} ->
      {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
  end

  # Increment stats on an existing entity WITHOUT touching its canonical/normalized
  # name — a fuzzy merge keeps the resolved entity's identity, only the mention count
  # and last_seen advance.
  defp bump_entity!(repo, %Entity{} = entity, mentioned_at, repo_opts) do
    attrs = %{
      mention_count: (entity.mention_count || 0) + 1,
      first_seen: entity.first_seen || mentioned_at,
      last_seen: mentioned_at
    }

    case entity |> Entity.changeset(attrs) |> repo.update(repo_opts) do
      {:ok, saved} -> saved.id
      {:error, changeset} -> throw({:entity_error, changeset})
    end
  end

  defp create_entity!(
         repo,
         bank_id,
         name,
         normalized_name,
         type,
         mentioned_at,
         res_ctx,
         repo_opts
       ) do
    attrs = %{
      bank_id: bank_id,
      canonical_name: name,
      normalized_name: normalized_name,
      entity_type: type || @default_entity_type,
      mention_count: 1,
      first_seen: mentioned_at,
      last_seen: mentioned_at
    }

    case %Entity{} |> Entity.changeset(attrs) |> repo.insert(repo_opts) do
      {:ok, saved} ->
        maybe_store_name_embedding(repo, saved, name, res_ctx, repo_opts)
        saved.id

      {:error, changeset} ->
        throw({:entity_error, changeset})
    end
  end

  # Persist the new entity's canonical-name embedding so future retains can
  # resolve semantic variants to it. No-op when semantic recall is disabled or the
  # embedder fails — resolution simply degrades to lexical for this entity.
  defp maybe_store_name_embedding(_repo, _entity, _name, %{semantic?: false}, _repo_opts), do: :ok

  defp maybe_store_name_embedding(repo, entity, name, res_ctx, repo_opts) do
    case res_ctx.embedder.embed(name, EmbeddingProfile.embedder_opts(res_ctx.profile)) do
      {:ok, vector} when is_list(vector) and vector != [] ->
        repo.insert(
          %EntityEmbedding{
            entity_id: entity.id,
            embedded_dim: res_ctx.profile["embedding_dim"],
            embedded_model: res_ctx.profile["model_id"],
            embedding: Pgvector.new(vector)
          },
          Keyword.merge(repo_opts, on_conflict: :nothing, conflict_target: [:entity_id])
        )

        :ok

      _ ->
        :ok
    end
  end

  # Candidate strategy selection, mirroring Hindsight's `entity_lookup` knob:
  # :full forces the substring fallback, :trigram forces trigram, :auto (default)
  # uses trigram iff the pg_trgm extension is installed.
  defp use_trigram_lookup?(repo, repo_opts) do
    case Application.get_env(:foresight, :entity_lookup_strategy, :auto) do
      :full -> false
      :trigram -> true
      _ -> pg_trgm_available?(repo, repo_opts)
    end
  end

  defp pg_trgm_available?(repo, repo_opts) do
    key = {__MODULE__, :pg_trgm_available, repo}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        available =
          case repo.query(
                 "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')",
                 [],
                 repo_opts
               ) do
            {:ok, %{rows: [[true]]}} -> true
            _ -> false
          end

        :persistent_term.put(key, available)
        available

      cached ->
        cached
    end
  end

  # Fuzzy candidates for `name` as scorer inputs:
  # %{id, name, last_seen, cooccurring, semantic_similarity}. Lexical candidates come
  # from trigram/substring (semantic 0.0); the semantic arm unions in embedding-
  # similar entities carrying their cosine. Both arms are restricted to the batch-start
  # entity set so same-retain creations are never candidates.
  defp scorer_candidates(repo, bank_id, name, res_ctx, repo_opts) do
    lexical_rows = lexical_candidate_rows(repo, bank_id, name, res_ctx, repo_opts)

    semantic_rows =
      if res_ctx.semantic?,
        do: semantic_candidate_rows(repo, bank_id, name, res_ctx, repo_opts),
        else: []

    merge_candidate_rows(lexical_rows, semantic_rows, res_ctx.cooccurrence)
  end

  defp lexical_candidate_rows(repo, bank_id, name, res_ctx, repo_opts) do
    if res_ctx.trigram? do
      repo.all(
        from(e in Entity,
          where:
            e.bank_id == ^bank_id and
              fragment("similarity(lower(?), lower(?)) >= 0.15", e.canonical_name, ^name),
          select: %{id: e.id, canonical_name: e.canonical_name, last_seen: e.last_seen}
        ),
        repo_opts
      )
      |> Enum.filter(&MapSet.member?(res_ctx.prebatch_ids, &1.id))
    else
      Enum.filter(res_ctx.bank_entities, &Resolution.candidate_match?(name, &1.canonical_name))
    end
  end

  defp semantic_candidate_rows(repo, bank_id, name, res_ctx, repo_opts) do
    case res_ctx.embedder.embed(name, EmbeddingProfile.embedder_opts(res_ctx.profile)) do
      {:ok, vector} when is_list(vector) and vector != [] ->
        mvec = Pgvector.new(vector)
        dim = res_ctx.profile["embedding_dim"]
        max_distance = 1.0 - semantic_similarity_threshold()
        limit = semantic_candidate_limit()

        repo.all(
          from(ee in EntityEmbedding,
            join: e in Entity,
            on: e.id == ee.entity_id,
            where:
              e.bank_id == ^bank_id and ee.embedded_dim == ^dim and
                fragment("(? <=> ?) <= ?", ee.embedding, ^mvec, ^max_distance),
            order_by: fragment("? <=> ?", ee.embedding, ^mvec),
            limit: ^limit,
            select: %{
              id: e.id,
              canonical_name: e.canonical_name,
              last_seen: e.last_seen,
              distance: fragment("? <=> ?", ee.embedding, ^mvec)
            }
          ),
          repo_opts
        )
        |> Enum.filter(&MapSet.member?(res_ctx.prebatch_ids, &1.id))
        |> Enum.map(&Map.put(&1, :semantic_similarity, 1.0 - &1.distance))

      _ ->
        []
    end
  end

  # Union lexical (semantic 0.0) and semantic (carrying cosine) rows by id, taking the
  # stronger semantic signal, and attach each candidate's co-occurrence set.
  defp merge_candidate_rows(lexical_rows, semantic_rows, cooccurrence) do
    base =
      Map.new(lexical_rows, fn r ->
        {r.id, %{id: r.id, name: r.canonical_name, last_seen: r.last_seen, semantic: 0.0}}
      end)

    merged =
      Enum.reduce(semantic_rows, base, fn r, acc ->
        entry =
          Map.get(acc, r.id, %{
            id: r.id,
            name: r.canonical_name,
            last_seen: r.last_seen,
            semantic: 0.0
          })

        Map.put(acc, r.id, %{entry | semantic: max(entry.semantic, r.semantic_similarity)})
      end)

    Enum.map(Map.values(merged), fn c ->
      %{
        id: c.id,
        name: c.name,
        last_seen: c.last_seen,
        cooccurring: Map.get(cooccurrence, c.id, MapSet.new()),
        semantic_similarity: c.semantic
      }
    end)
  end

  defp semantic_recall_enabled?,
    do: Application.get_env(:foresight, :entity_semantic_recall, false) == true

  defp semantic_similarity_threshold,
    do: Application.get_env(:foresight, :entity_semantic_similarity_threshold, 0.5)

  defp semantic_candidate_limit,
    do: Application.get_env(:foresight, :entity_semantic_limit, 20)

  defp load_bank_entities(repo, bank_id, repo_opts) do
    repo.all(
      from(e in Entity,
        where: e.bank_id == ^bank_id,
        select: %{id: e.id, canonical_name: e.canonical_name, last_seen: e.last_seen}
      ),
      repo_opts
    )
  end

  # entity_id => MapSet of lowercased canonical names it co-occurs with (both link
  # directions), mirroring Hindsight's cooccurrence_map. Names comparable to the
  # lowercased `nearby` set the scorer builds.
  defp build_cooccurrence_index(repo, bank_id, repo_opts) do
    id_to_name =
      repo.all(
        from(e in Entity, where: e.bank_id == ^bank_id, select: {e.id, e.canonical_name}),
        repo_opts
      )
      |> Map.new(fn {id, name} -> {id, String.downcase(name)} end)

    repo.all(
      from(l in EntityLink,
        where: l.bank_id == ^bank_id and l.link_type == "co_occurrence",
        select: {l.source_entity_id, l.target_entity_id}
      ),
      repo_opts
    )
    |> Enum.reduce(%{}, fn {source_id, target_id}, acc ->
      acc
      |> add_cooccurrence(source_id, Map.get(id_to_name, target_id))
      |> add_cooccurrence(target_id, Map.get(id_to_name, source_id))
    end)
  end

  defp add_cooccurrence(acc, _id, nil), do: acc

  defp add_cooccurrence(acc, id, name),
    do: Map.update(acc, id, MapSet.new([name]), &MapSet.put(&1, name))

  defp link_memory_unit_entities(repo, memory_unit_id, entity_ids, repo_opts) do
    Enum.reduce_while(entity_ids, {:ok, []}, fn entity_id, {:ok, acc} ->
      changeset =
        MemoryUnitEntity.changeset(%MemoryUnitEntity{}, %{
          memory_unit_id: memory_unit_id,
          entity_id: entity_id
        })

      case repo.insert(
             changeset,
             Keyword.merge(repo_opts,
               on_conflict: :nothing,
               conflict_target: [:memory_unit_id, :entity_id]
             )
           ) do
        {:ok, link} ->
          {:cont, {:ok, [link | acc]}}

        {:error, changeset} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}
      end
    end)
  end

  defp upsert_entity_links(_repo, _bank_id, [], _repo_opts), do: {:ok, []}
  defp upsert_entity_links(_repo, _bank_id, [_single], _repo_opts), do: {:ok, []}

  defp upsert_entity_links(repo, bank_id, entity_ids, repo_opts) do
    entity_ids
    |> canonical_pairs()
    |> Enum.reduce_while({:ok, []}, fn {source_id, target_id}, {:ok, acc} ->
      link =
        repo.get_by(
          EntityLink,
          [
            bank_id: bank_id,
            source_entity_id: source_id,
            target_entity_id: target_id,
            link_type: "co_occurrence"
          ],
          repo_opts
        ) || %EntityLink{weight: 0}

      # weight counts the units in which the pair co-occurs (Hindsight's
      # `ON CONFLICT ... weight = weight + 1`). The schema default of 1 on a fresh
      # struct used to make a first co-occurrence start at 2.
      attrs = %{
        bank_id: bank_id,
        source_entity_id: source_id,
        target_entity_id: target_id,
        link_type: "co_occurrence",
        weight: link.weight + 1
      }

      case link |> EntityLink.changeset(attrs) |> repo.insert_or_update(repo_opts) do
        {:ok, saved} ->
          {:cont, {:ok, [saved | acc]}}

        {:error, changeset} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}
      end
    end)
  end

  defp normalize_fact_type(nil), do: :experience
  defp normalize_fact_type(type) when type in [:world, :experience, :observation], do: type

  defp normalize_fact_type(type) when type in ["world", "experience", "observation"],
    do: String.to_existing_atom(type)

  defp normalize_fact_type(_type), do: :experience

  defp normalize_clear_bank_type(nil), do: {:ok, nil}
  defp normalize_clear_bank_type(""), do: {:ok, nil}

  defp normalize_clear_bank_type(type) when type in [:world, :experience, :observation],
    do: {:ok, type}

  defp normalize_clear_bank_type(type) when type in ["world", "experience", "observation"],
    do: {:ok, String.to_existing_atom(type)}

  defp normalize_clear_bank_type(_type),
    do:
      {:error,
       Error.new(:invalid_request, %{
         message: "type must be one of world, experience, observation"
       })}

  defp normalize_source_memory_ids(%{"source_memory_ids" => ids}) when is_list(ids), do: ids
  defp normalize_source_memory_ids(%{"source_fact_ids" => ids}) when is_list(ids), do: ids
  defp normalize_source_memory_ids(_item), do: []

  defp bank_changeset(bank_id) do
    Bank.changeset(%Bank{}, %{id: bank_id, name: bank_id, mission: ""})
  end

  defp bank_record(bank_id, repo, repo_opts) do
    repo.get(Bank, bank_id, repo_opts) || %Bank{id: bank_id}
  end

  defp ensure_bank_exists(repo, bank_id, repo_opts) do
    case repo.get(Bank, bank_id, repo_opts) do
      %Bank{} = bank ->
        {:ok, bank}

      nil ->
        bank_changeset(bank_id)
        |> repo.insert(Keyword.merge(repo_opts, on_conflict: :nothing, conflict_target: [:id]))
        |> case do
          {:ok, %Bank{} = bank} ->
            {:ok, bank}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
        end
    end
  end

  defp bank_document_record(repo, bank_id, external_id, repo_opts) do
    repo.one(
      from(document in Document,
        where: document.bank_id == ^bank_id and document.external_id == ^external_id
      ),
      repo_opts
    ) || %Document{}
  end

  defp maybe_filter_active_directives(query, true),
    do: from(directive in query, where: directive.is_active == true)

  defp maybe_filter_active_directives(query, _active_only), do: query

  defp directive_to_response(directive) do
    %{
      "id" => directive.id,
      "bank_id" => directive.bank_id,
      "name" => directive.name,
      "content" => directive.content,
      "priority" => directive.priority,
      "is_active" => directive.is_active,
      "tags" => directive.tags || [],
      "created_at" => format_datetime(directive.inserted_at),
      "updated_at" => format_datetime(directive.updated_at)
    }
  end

  defp mental_model_document_attrs(document, bank_id, attrs) do
    metadata = document.metadata || %{}

    %{
      bank_id: bank_id,
      external_id: attrs["id"],
      title: attrs["name"],
      original_text:
        document.original_text ||
          "Pending mental model content generation for #{attrs["source_query"]}",
      tags: Map.get(attrs, "tags", []),
      metadata:
        metadata
        |> Map.merge(%{
          "document_type" => "mental_model",
          "source_query" => attrs["source_query"],
          "max_tokens" => Map.get(attrs, "max_tokens", 2048),
          "trigger" => Map.get(attrs, "trigger", %{}),
          "reflect_response" => Map.get(metadata, "reflect_response"),
          "last_refreshed_at" => Map.get(metadata, "last_refreshed_at"),
          "is_stale" => Map.get(metadata, "is_stale", true),
          "history" => normalize_mental_model_history(Map.get(metadata, "history", []))
        })
    }
  end

  defp mental_model_document_patch(document, attrs) do
    metadata = document.metadata || %{}

    trigger =
      case Map.fetch(attrs, "trigger") do
        {:ok, value} -> value
        :error -> Map.get(metadata, "trigger", %{})
      end

    max_tokens =
      case Map.fetch(attrs, "max_tokens") do
        {:ok, value} -> value
        :error -> Map.get(metadata, "max_tokens", 2048)
      end

    patch = %{
      title: Map.get(attrs, "name", document.title),
      tags: Map.get(attrs, "tags", document.tags),
      metadata:
        metadata
        |> Map.put("document_type", "mental_model")
        |> maybe_put_patch("source_query", Map.get(attrs, "source_query"))
        |> Map.put("max_tokens", max_tokens)
        |> Map.put("trigger", trigger)
    }

    patch
  end

  # Staleness is computed only for the detail level that reports it; the
  # metadata/content projections never show it, so they skip the query.
  defp mental_model_staleness(_repo, _bank_id, _document, _repo_opts, detail)
       when detail in ["metadata", "content"],
       do: nil

  defp mental_model_staleness(repo, bank_id, document, repo_opts, _detail),
    do: Foresight.Reflect.MentalModels.stale?(repo, bank_id, document, repo_opts)

  # `staleness` is the computed {is_stale, reason} (Foresight.Reflect.MentalModels);
  # when a caller has not computed it the stored flag stands, as before.
  defp mental_model_to_response(document, detail, staleness) do
    metadata = document.metadata || %{}

    base = %{
      "id" => document.external_id,
      "bank_id" => document.bank_id,
      "name" => document.title || document.external_id,
      "source_query" => metadata["source_query"],
      "tags" => document.tags || [],
      "max_tokens" => metadata["max_tokens"],
      "trigger" => metadata["trigger"],
      "last_refreshed_at" => metadata["last_refreshed_at"],
      "created_at" => format_datetime(document.inserted_at)
    }

    case detail do
      "metadata" ->
        base

      "content" ->
        Map.put(base, "content", document.original_text)

      _ ->
        {is_stale, reason} =
          case staleness do
            {stale?, reason} -> {stale?, reason}
            nil -> {metadata["is_stale"], nil}
          end

        base
        |> Map.put("content", document.original_text)
        |> Map.put("reflect_response", metadata["reflect_response"])
        |> Map.put("is_stale", is_stale)
        |> Map.put("staleness_reason", reason)
    end
  end

  defp maybe_record_mental_model_history(metadata, previous_content, previous_reflect_response) do
    entry = %{
      "previous_content" => previous_content,
      "changed_at" => format_datetime(now()),
      "previous_reflect_response" => slim_reflect_response(previous_reflect_response)
    }

    [entry | normalize_mental_model_history(metadata["history"])]
  end

  defp normalize_mental_model_history(history) when is_list(history) do
    Enum.map(history, fn entry ->
      %{
        "previous_content" => Map.get(entry, "previous_content"),
        "changed_at" => Map.get(entry, "changed_at"),
        "previous_reflect_response" => Map.get(entry, "previous_reflect_response")
      }
    end)
  end

  defp normalize_mental_model_history(_history), do: []

  defp normalize_observation_history(history) when is_list(history) do
    Enum.map(history, fn entry ->
      %{
        "previous_content" => Map.get(entry, "previous_content"),
        "changed_at" => Map.get(entry, "changed_at"),
        "source_facts" => List.wrap(Map.get(entry, "source_facts", []))
      }
      |> compact_map_preserve_nil(["source_facts"])
    end)
  end

  defp normalize_observation_history(_history), do: []

  defp slim_reflect_response(%{"based_on" => based_on}), do: %{"based_on" => based_on}
  defp slim_reflect_response(%{based_on: based_on}), do: %{"based_on" => based_on}
  defp slim_reflect_response(_other), do: nil

  defp maybe_put_mental_model_history_for_update(attrs, update_attrs, metadata, previous_content)
       when is_map(attrs) and is_map(update_attrs) do
    case fetch_mental_model_content(update_attrs) do
      {:ok, content} when content != previous_content ->
        history =
          maybe_record_mental_model_history(
            metadata,
            previous_content,
            metadata["reflect_response"]
          )

        maybe_put_history(attrs, history)

      _ ->
        attrs
    end
  end

  defp fetch_mental_model_content(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "content") -> {:ok, attrs["content"]}
      Map.has_key?(attrs, :content) -> {:ok, attrs[:content]}
      true -> :error
    end
  end

  defp maybe_put_history(attrs, history) when is_map(attrs) and is_list(history) do
    Map.update(attrs, :metadata, %{"history" => history}, &Map.put(&1, "history", history))
  end

  defp template_directives_by_name(repo, bank_id, repo_opts) do
    from(directive in Directive, where: directive.bank_id == ^bank_id)
    |> repo.all(repo_opts)
    |> Map.new(&{&1.name, &1})
  end

  defp template_mental_models_by_id(repo, bank_id, repo_opts) do
    from(document in Document,
      where: document.bank_id == ^bank_id,
      where: fragment("?->>'document_type' = 'mental_model'", document.metadata)
    )
    |> repo.all(repo_opts)
    |> Map.new(&{&1.external_id, &1})
  end

  defp upsert_template_bank(repo, nil, bank_id, template_bank_config, repo_opts) do
    attrs = %{
      id: bank_id,
      name: bank_id,
      mission: "",
      config_overrides: template_bank_config || %{}
    }

    %Bank{}
    |> Bank.changeset(attrs)
    |> repo.insert(repo_opts)
  end

  defp upsert_template_bank(_repo, %Bank{} = bank, _bank_id, nil, _repo_opts), do: {:ok, bank}

  defp upsert_template_bank(repo, %Bank{} = bank, _bank_id, template_bank_config, repo_opts) do
    bank
    |> Bank.changeset(%{config_overrides: template_bank_config})
    |> repo.update(repo_opts)
  end

  defp import_template_directives(_repo, _bank_id, [], _repo_opts), do: {:ok, []}

  defp import_template_directives(repo, bank_id, directives, repo_opts) do
    Enum.reduce_while(directives, {:ok, []}, fn directive_attrs, {:ok, acc} ->
      existing =
        repo.one(
          from(directive in Directive,
            where: directive.bank_id == ^bank_id and directive.name == ^directive_attrs["name"]
          ),
          repo_opts
        ) || %Directive{}

      attrs = %{
        bank_id: bank_id,
        name: directive_attrs["name"],
        content: directive_attrs["content"],
        priority: Map.get(directive_attrs, "priority", 0),
        is_active: Map.get(directive_attrs, "is_active", true),
        tags: Map.get(directive_attrs, "tags", [])
      }

      case existing |> Directive.changeset(attrs) |> repo.insert_or_update(repo_opts) do
        {:ok, saved} ->
          {:cont, {:ok, [saved | acc]}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}
      end
    end)
  end

  defp import_template_mental_models(_repo, _bank_id, [], _repo_opts), do: {:ok, []}

  defp import_template_mental_models(repo, bank_id, mental_models, repo_opts) do
    Enum.reduce_while(mental_models, {:ok, []}, fn model_attrs, {:ok, acc} ->
      existing = bank_document_record(repo, bank_id, model_attrs["id"], repo_opts)
      existing_metadata = existing.metadata || %{}

      attrs = %{
        bank_id: bank_id,
        external_id: model_attrs["id"],
        title: model_attrs["name"],
        original_text:
          existing.original_text ||
            "Pending mental model content generation for #{model_attrs["source_query"]}",
        tags: Map.get(model_attrs, "tags", []),
        metadata:
          existing_metadata
          |> Map.merge(%{
            "document_type" => "mental_model",
            "source_query" => model_attrs["source_query"],
            "max_tokens" => Map.get(model_attrs, "max_tokens", 2048),
            "trigger" => Map.get(model_attrs, "trigger", %{})
          })
      }

      case existing |> Document.changeset(attrs) |> repo.insert_or_update(repo_opts) do
        {:ok, saved} ->
          {:cont, {:ok, [saved | acc]}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}}
      end
    end)
  end

  defp tenant_repo_opts(%{prefix: prefix}) when is_binary(prefix) and prefix != "" do
    [prefix: prefix]
  end

  defp tenant_repo_opts(_ctx), do: []

  defp with_tenant_scope(ctx, repo, opts, fun) when is_function(fun, 0) do
    tenancy_opts = [repo: repo] ++ Keyword.take(opts, [:rls_enabled])
    Foresight.Tenancy.with_tenant_role(ctx, fun, tenancy_opts)
  end

  defp insert_mutation_audit_log(repo, ctx, action, request, response, repo_opts, started_at) do
    actor = ctx.role_name || ctx.tenant_id

    %AuditLog{}
    |> AuditLog.changeset(%{
      action: action,
      transport: "backend",
      bank_id: ctx.bank,
      started_at: started_at,
      ended_at: now(),
      request: normalize_audit_payload(request),
      response: normalize_audit_payload(response),
      metadata: %{
        "actor" => actor,
        "tenant_id" => ctx.tenant_id,
        "mode" => ctx.mode && Atom.to_string(ctx.mode)
      }
    })
    |> repo.insert(repo_opts)
    |> case do
      {:ok, audit_log} ->
        {:ok, audit_log}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
    end
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_transaction_result({:error, reason}),
    do: {:error, Error.new(:invalid_request, %{message: inspect(reason)})}

  defp maybe_enqueue_consolidation_webhooks({:ok, result} = ok, ctx, opts) do
    repo_opts = tenant_repo_opts(ctx)

    payload = %{
      "bank_id" => ctx.bank,
      "result" => result
    }

    case Webhooks.enqueue_event(
           ctx,
           "consolidation.completed",
           payload,
           Keyword.put(opts, :repo_opts, repo_opts)
         ) do
      :ok -> ok
      {:error, _error} -> ok
    end
  end

  defp maybe_enqueue_consolidation_webhooks(result, _ctx, _opts), do: result

  defp normalize_audit_payload(%{} = payload) do
    Map.new(payload, fn {key, value} -> {to_string(key), normalize_audit_payload(value)} end)
  end

  defp normalize_audit_payload(list) when is_list(list),
    do: Enum.map(list, &normalize_audit_payload/1)

  defp normalize_audit_payload(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp normalize_audit_payload(value), do: value

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp normalize_bank_attrs(bank_id, attrs) do
    %{
      id: bank_id,
      name: Map.get(attrs, "name") || Map.get(attrs, :name) || bank_id,
      mission: Map.get(attrs, "mission") || Map.get(attrs, :mission) || "",
      background: Map.get(attrs, "background") || Map.get(attrs, :background),
      disposition: Map.get(attrs, "disposition") || Map.get(attrs, :disposition) || %{},
      auto_consolidate:
        Map.get(attrs, "auto_consolidate", Map.get(attrs, :auto_consolidate, false))
    }
  end

  defp normalize_patch_bank_attrs(attrs) do
    %{}
    |> maybe_put_patch(:name, Map.get(attrs, "name") || Map.get(attrs, :name))
    |> maybe_put_patch(:mission, Map.get(attrs, "mission") || Map.get(attrs, :mission))
    |> maybe_put_patch(:background, Map.get(attrs, "background") || Map.get(attrs, :background))
    |> maybe_put_patch(
      :disposition,
      Map.get(attrs, "disposition") || Map.get(attrs, :disposition)
    )
    |> maybe_put_patch(
      :auto_consolidate,
      Map.get(attrs, "auto_consolidate", Map.get(attrs, :auto_consolidate))
    )
  end

  defp normalize_bank_config_updates(updates) do
    case Fields.normalize_updates(updates) do
      {:ok, normalized_updates} ->
        case Guard.validate_updates(normalized_updates) do
          :ok -> {:ok, normalized_updates}
          {:error, %Error{} = error} -> {:error, error}
        end

      {:error, unknown_fields} ->
        {:error,
         Error.new(:invalid_request, %{
           message:
             "Unknown configuration fields: #{inspect(unknown_fields)}. Valid configurable fields: #{inspect(Fields.configurable_fields())}"
         })}
    end
  end

  defp normalize_template_manifest(%{"version" => version} = manifest) when is_binary(version) do
    with {:ok, normalized_bank} <- normalize_template_bank_config(Map.get(manifest, "bank")),
         {:ok, directives} <- normalize_template_directives(Map.get(manifest, "directives")),
         {:ok, mental_models} <-
           normalize_template_mental_models(Map.get(manifest, "mental_models")) do
      {:ok,
       %{
         "version" => version,
         "bank" => normalized_bank,
         "directives" => directives,
         "mental_models" => mental_models,
         "dry_run" => Map.get(manifest, "dry_run", false)
       }}
    end
  end

  defp normalize_template_manifest(_manifest) do
    {:error, Error.new(:invalid_request, %{message: "template manifest requires version"})}
  end

  defp normalize_template_bank_config(nil), do: {:ok, nil}

  defp normalize_template_bank_config(config) when is_map(config) do
    case normalize_bank_config_updates(config) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_template_bank_config(_other) do
    {:error, Error.new(:invalid_request, %{message: "bank must be an object"})}
  end

  defp normalize_template_directives(nil), do: {:ok, []}

  defp normalize_template_directives(directives) when is_list(directives) do
    directives
    |> Enum.reduce_while({:ok, []}, fn directive, {:ok, acc} ->
      case normalize_template_directive(directive) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_template_directives(_other) do
    {:error, Error.new(:invalid_request, %{message: "directives must be an array"})}
  end

  defp normalize_template_directive(%{"name" => name, "content" => content} = directive)
       when is_binary(name) and is_binary(content) do
    {:ok,
     %{
       "name" => name,
       "content" => content,
       "priority" => Map.get(directive, "priority", 0),
       "is_active" => Map.get(directive, "is_active", true),
       "tags" => List.wrap(Map.get(directive, "tags", []))
     }}
  end

  defp normalize_template_directive(_directive) do
    {:error,
     Error.new(:invalid_request, %{message: "each directive must include name and content"})}
  end

  defp normalize_template_mental_models(nil), do: {:ok, []}

  defp normalize_template_mental_models(models) when is_list(models) do
    models
    |> Enum.reduce_while({:ok, []}, fn model, {:ok, acc} ->
      case normalize_template_mental_model(model) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_template_mental_models(_other) do
    {:error, Error.new(:invalid_request, %{message: "mental_models must be an array"})}
  end

  defp normalize_template_mental_model(
         %{"id" => id, "name" => name, "source_query" => source_query} = model
       )
       when is_binary(id) and is_binary(name) and is_binary(source_query) do
    {:ok,
     %{
       "id" => id,
       "name" => name,
       "source_query" => source_query,
       "tags" => List.wrap(Map.get(model, "tags", [])),
       "max_tokens" => Map.get(model, "max_tokens", 2048),
       "trigger" => normalize_template_trigger(Map.get(model, "trigger", %{}))
     }}
  end

  defp normalize_template_mental_model(_model) do
    {:error,
     Error.new(:invalid_request, %{
       message: "each mental model must include id, name, and source_query"
     })}
  end

  defp normalize_template_trigger(trigger) when is_map(trigger), do: trigger
  defp normalize_template_trigger(_other), do: %{}

  defp bank_to_response(bank, repo, repo_opts) do
    fact_count =
      repo.aggregate(from(unit in MemoryUnit, where: unit.bank_id == ^bank.id), :count, repo_opts)

    %{
      "bank_id" => bank.id,
      "name" => bank.name,
      "disposition" => bank.disposition || %{},
      "mission" => bank.mission,
      "auto_consolidate" => bank.auto_consolidate,
      "created_at" => format_datetime(bank.inserted_at),
      "updated_at" => format_datetime(bank.updated_at),
      "fact_count" => fact_count,
      "last_document_at" => nil
    }
  end

  defp bank_profile_response(bank) do
    %{
      "bank_id" => bank.id,
      "name" => bank.name,
      "mission" => bank.mission || "",
      "background" => bank.background || bank.mission || "",
      "disposition" => bank.disposition || %{},
      "auto_consolidate" => bank.auto_consolidate
    }
  end

  defp bank_config_response(ctx, bank, runtime_config) do
    resolved = Resolver.resolve(ctx, bank.config_overrides || %{}, runtime_config)

    %{
      "bank_id" => bank.id,
      "config" => resolved.config,
      "overrides" => resolved.overrides
    }
  end

  defp effective_embedding_profile(ctx, bank_overrides, runtime_cfg, opts) do
    resolved = Resolver.resolve(ctx, bank_overrides || %{}, runtime_cfg)

    EmbeddingProfile.resolve(resolved.config,
      embedder: Keyword.fetch!(opts, :embedder),
      runtime_config: runtime_cfg
    )
  end

  defp maybe_enqueue_embedding_backfill(_ctx, _bank_id, previous_profile, next_profile, _opts)
       when not is_map(previous_profile) or not is_map(next_profile),
       do: :ok

  defp maybe_enqueue_embedding_backfill(ctx, bank_id, previous_profile, next_profile, opts) do
    if EmbeddingProfile.changed?(previous_profile, next_profile) do
      repo = Keyword.fetch!(opts, :repo)
      queue = Keyword.fetch!(opts, :queue)

      # The bank's embedding profile is changing. Clear the pinned profile so the
      # re-embedding backfill (and any retains at the new profile) can re-pin the
      # bank; otherwise the one-profile-per-bank trigger would reject every
      # re-embed and wedge the bank. Runs inside the config-change transaction and
      # tenant scope; the backfill re-pins from the first re-embedded write.
      reset_bank_embedding_pin(repo, ctx, bank_id)

      case queue.enqueue_embedding_backfill(
             ctx,
             %{
               "bank_id" => bank_id,
               "previous_profile" => previous_profile,
               "target_profile" => next_profile
             },
             opts
           ) do
        {:ok, _ack} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp reset_bank_embedding_pin(repo, ctx, bank_id) do
    from(b in Bank, where: b.id == ^bank_id)
    |> repo.update_all([set: [embedding_dim: nil, embedding_model: nil]], tenant_repo_opts(ctx))

    :ok
  end

  defp payload_embedding_profile(payload, runtime_cfg, opts) do
    target_profile = Map.get(payload, "target_profile", %{})

    EmbeddingProfile.resolve(
      %{
        "embed_model" => target_profile["model_id"],
        "embedding_dim" => target_profile["embedding_dim"]
      },
      embedder: Keyword.fetch!(opts, :embedder),
      runtime_config: runtime_cfg
    )
  end

  # Cosine-similarity floor against the profile's vector column. The parameter cast
  # has to match the column's storage type: halfvec columns (3072) compare against a
  # halfvec parameter, the rest against vector. Fragments are literal, hence two.
  defp where_similarity_at_least(query, vector_field, query_vector, floor) do
    if EmbeddingProfile.half?(vector_field) do
      where(
        query,
        [unit],
        fragment(
          "(1 - (? <=> ?::halfvec)) >= ?",
          field(unit, ^vector_field),
          ^query_vector,
          ^floor
        )
      )
    else
      where(
        query,
        [unit],
        fragment(
          "(1 - (? <=> ?::vector)) >= ?",
          field(unit, ^vector_field),
          ^query_vector,
          ^floor
        )
      )
    end
  end

  defp vector_value(profile, embedding) do
    EmbeddingProfile.to_vector(profile["vector_field"], embedding)
  end

  # Every vector column is written: the profile's column gets the vector, the others
  # are cleared, so a re-embed under a new profile never leaves a stale vector behind.
  defp vector_attrs(profile, embedding) do
    EmbeddingProfile.vector_fields()
    |> Map.new(&{&1, nil})
    |> Map.put(profile["vector_field"], vector_value(profile, embedding))
  end

  defp memory_unit_vector(memory_unit) do
    EmbeddingProfile.vector(memory_unit)
  end

  defp memory_unit_vector_list(memory_unit) do
    case memory_unit_vector(memory_unit) do
      nil -> nil
      vector -> Pgvector.to_list(vector)
    end
  end

  defp memory_unit_similarity(memory_unit, query_embedding) do
    case memory_unit_vector_list(memory_unit) do
      nil -> 0.0
      vector -> cosine_similarity(vector, query_embedding)
    end
  end

  defp export_template_bank_config(resolved_config) do
    resolved_config
    |> Fields.normalize_layer()
    |> Map.take(Foresight.BankTemplate.Schema.template_config_field_names())
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp export_template_directives(repo, bank_id, repo_opts) do
    from(directive in Directive,
      where: directive.bank_id == ^bank_id,
      order_by: [asc: directive.name, desc: directive.priority, asc: directive.inserted_at]
    )
    |> repo.all(repo_opts)
    |> Enum.map(fn directive ->
      %{
        "name" => directive.name,
        "content" => directive.content,
        "priority" => directive.priority,
        "is_active" => directive.is_active,
        "tags" => directive.tags || []
      }
    end)
  end

  defp export_template_mental_models(repo, bank_id, repo_opts) do
    from(document in Document,
      where: document.bank_id == ^bank_id,
      where: fragment("?->>'document_type' = 'mental_model'", document.metadata),
      order_by: [asc: document.external_id]
    )
    |> repo.all(repo_opts)
    |> Enum.map(&template_mental_model_from_document/1)
  end

  defp template_mental_model_from_document(document) do
    metadata = document.metadata || %{}

    %{
      "id" => document.external_id,
      "name" => document.title || document.external_id,
      "source_query" =>
        metadata["source_query"] || metadata["scope_key"] || document.title ||
          document.external_id,
      "tags" => document.tags || [],
      "max_tokens" => metadata["max_tokens"] || 2048,
      "trigger" => metadata["trigger"] || %{}
    }
  end

  defp runtime_config(opts), do: Keyword.get(opts, :config, %{})

  defp resolve_runtime_bank_config(repo, ctx, repo_opts, runtime_config) do
    bank_overrides =
      case repo.get(Bank, ctx.bank, repo_opts) do
        %Bank{} = bank -> bank.config_overrides || %{}
        _ -> %{}
      end

    Resolver.resolve(ctx, bank_overrides, runtime_config)
  end

  defp apply_runtime_recall_config(params, payload, runtime_config) do
    params
    |> maybe_apply_runtime_recall_max_tokens(payload, runtime_config)
    |> Map.put("recall_rerank_window", runtime_config["recall_rerank_window"])
    |> Map.put("recall_semantic_floor", runtime_config["recall_semantic_floor"])
    |> Map.put("recall_budget_function", runtime_config["recall_budget_function"])
    |> Map.put("recall_budget_fixed_low", runtime_config["recall_budget_fixed_low"])
    |> Map.put("recall_budget_fixed_mid", runtime_config["recall_budget_fixed_mid"])
    |> Map.put("recall_budget_fixed_high", runtime_config["recall_budget_fixed_high"])
    |> Map.put("recall_budget_adaptive_low", runtime_config["recall_budget_adaptive_low"])
    |> Map.put("recall_budget_adaptive_mid", runtime_config["recall_budget_adaptive_mid"])
    |> Map.put("recall_budget_adaptive_high", runtime_config["recall_budget_adaptive_high"])
    |> Map.put("recall_budget_min", runtime_config["recall_budget_min"])
    |> Map.put("recall_budget_max", runtime_config["recall_budget_max"])
    # A bank's learned fusion weights ride the same resolved-config path as
    # every other per-bank recall knob, so the fuser needs no extra bank lookup.
    |> Map.put("recall_fusion", runtime_config["recall_fusion"])
  end

  defp maybe_apply_runtime_recall_max_tokens(params, payload, runtime_config) do
    case {Map.has_key?(payload, "max_tokens"), runtime_config["recall_max_tokens"]} do
      {false, value} when is_integer(value) and value > 0 -> Map.put(params, "max_tokens", value)
      _ -> params
    end
  end

  defp apply_runtime_reflect_bank_profile(bank_profile, runtime_config) do
    bank_profile
    |> maybe_put_patch("mission", runtime_config["reflect_mission"] || bank_profile["mission"])
    |> Map.put(
      "disposition",
      bank_profile
      |> Map.get("disposition", %{})
      |> apply_runtime_disposition_overrides(runtime_config)
    )
  end

  defp apply_runtime_disposition_overrides(disposition, runtime_config) do
    disposition
    |> maybe_put_patch("skepticism", runtime_config["disposition_skepticism"])
    |> maybe_put_patch("literalism", runtime_config["disposition_literalism"])
    |> maybe_put_patch("empathy", runtime_config["disposition_empathy"])
  end

  defp runtime_llm_provider(runtime_config, role) do
    runtime_config[role_provider_key(role)] || runtime_config["llm_provider"]
  end

  defp runtime_llm_provider_opts(runtime_config, role) do
    []
    |> maybe_keyword_put(
      :model,
      runtime_config[role_model_key(role)] || runtime_config["llm_model"]
    )
    |> maybe_keyword_put(
      :base_url,
      runtime_config[role_base_url_key(role)] || runtime_config["llm_base_url"]
    )
    |> maybe_keyword_put(
      :api_key,
      runtime_config[role_api_key_key(role)] || runtime_config["llm_api_key"]
    )
  end

  defp role_provider_key(:extract), do: "llm_extract_provider"
  defp role_provider_key(:judge), do: "llm_judge_provider"
  defp role_provider_key(_role), do: "llm_reflect_provider"

  defp role_model_key(:extract), do: "llm_extract_model"
  defp role_model_key(:judge), do: "llm_judge_model"
  defp role_model_key(_role), do: "llm_reflect_model"

  defp role_base_url_key(:extract), do: "llm_extract_base_url"
  defp role_base_url_key(:judge), do: "llm_judge_base_url"
  defp role_base_url_key(_role), do: "llm_reflect_base_url"

  defp role_api_key_key(:extract), do: "llm_extract_api_key"
  defp role_api_key_key(:judge), do: "llm_judge_api_key"
  defp role_api_key_key(_role), do: "llm_reflect_api_key"

  defp maybe_filter_clear_fact_type(query, nil), do: query

  defp maybe_filter_clear_fact_type(query, fact_type),
    do: where(query, [unit], unit.fact_type == ^fact_type)

  defp maybe_put_patch(map, _key, nil), do: map
  defp maybe_put_patch(map, key, value), do: Map.put(map, key, value)

  defp maybe_keyword_put(keyword, _key, nil), do: keyword
  defp maybe_keyword_put(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp memory_unit_to_response(memory_unit) do
    %{
      "id" => memory_unit.id,
      "content" => memory_unit.content,
      "context" => memory_unit.context,
      "type" => Atom.to_string(memory_unit.fact_type),
      "tags" => memory_unit.tags,
      "observation_scopes" => memory_unit.observation_scopes,
      "metadata" => memory_unit.metadata,
      "date" => format_datetime(memory_unit.mentioned_at),
      "score" => memory_score(memory_unit),
      "source_fact_ids" =>
        case memory_unit.metadata["source_fact_ids"] do
          ids when is_list(ids) and ids != [] -> ids
          _ -> Enum.map(memory_unit.source_memory_ids || [], &to_string/1)
        end
    }
  end

  defp memory_unit_detail(memory_unit) do
    %{
      "id" => memory_unit.id,
      "text" => memory_unit.content,
      "content" => memory_unit.content,
      "context" => memory_unit.context,
      "type" => Atom.to_string(memory_unit.fact_type),
      "tags" => memory_unit.tags,
      "metadata" => memory_unit.metadata,
      "document_id" => memory_unit.document_ref,
      "mentioned_at" => format_datetime(memory_unit.mentioned_at),
      "occurred_at" => format_datetime(memory_unit.occurred_at),
      "occurred_start" => format_datetime(memory_unit.occurred_start),
      "occurred_end" => format_datetime(memory_unit.occurred_end),
      "source_fact_ids" => Enum.map(memory_unit.source_memory_ids || [], &to_string/1),
      "history" => [],
      "entities" => []
    }
    |> compact_map_preserve_nil(["document_id", "occurred_at", "occurred_start", "occurred_end"])
  end

  defp entity_to_response(entity) do
    %{
      "id" => entity.id,
      "canonical_name" => entity.canonical_name,
      "mention_count" => entity.mention_count,
      "first_seen" => format_datetime(entity.first_seen),
      "last_seen" => format_datetime(entity.last_seen)
    }
  end

  defp entity_graph_edge(edge) do
    %{
      "data" => %{
        "id" => "#{edge.source_id}-#{edge.target_id}",
        "source" => edge.source_id,
        "target" => edge.target_id,
        "linkType" => normalize_entity_graph_link_type(edge.link_type),
        "weight" => edge.weight,
        "color" => "#ffd700",
        "lineStyle" => "solid",
        "lastCooccurred" => format_datetime(edge.updated_at)
      }
    }
  end

  defp entity_graph_node_color(mention_count)
       when is_integer(mention_count) and mention_count > 1,
       do: "#42a5f5"

  defp entity_graph_node_color(_mention_count), do: "#90caf9"

  defp normalize_entity_graph_link_type("co_occurrence"), do: "cooccurrence"

  defp normalize_entity_graph_link_type(other) when is_binary(other),
    do: String.replace(other, "_", "")

  defp normalize_entity_graph_link_type(_other), do: "cooccurrence"

  defp memory_graph_node(unit, entity_names) do
    %{
      "data" => %{
        "id" => unit.id,
        "label" => memory_graph_label(unit.content),
        "text" => unit.content,
        "date" => format_datetime(unit.mentioned_at),
        "context" => unit.context || "",
        "entities" => Enum.join(entity_names, ", "),
        "color" => memory_graph_node_color(unit.fact_type)
      }
    }
  end

  defp memory_graph_table_row(unit, entity_names) do
    %{
      "id" => unit.id,
      "text" => unit.content,
      "context" => blank_to_na(unit.context),
      "occurred_start" => format_datetime(unit.occurred_start),
      "occurred_end" => format_datetime(unit.occurred_end),
      "mentioned_at" => format_datetime(unit.mentioned_at),
      "date" => format_graph_table_date(unit.mentioned_at),
      "entities" => Enum.join(entity_names, ", "),
      "document_id" => unit.document_ref,
      "chunk_id" => memory_graph_chunk_id(unit),
      "fact_type" => Atom.to_string(unit.fact_type),
      "tags" => unit.tags,
      "created_at" => format_datetime(unit.inserted_at),
      "proof_count" => unit.proof_count
    }
  end

  defp memory_graph_edges(units, entity_names_by_unit) do
    units_by_id = Map.new(units, &{&1.id, &1})

    entity_edges =
      units
      |> Enum.with_index()
      |> Enum.flat_map(fn {source, index} ->
        remaining = Enum.drop(units, index + 1)
        source_entities = Map.get(entity_names_by_unit, source.id, [])

        Enum.flat_map(remaining, fn target ->
          target_entities = Map.get(entity_names_by_unit, target.id, [])

          source_entities
          |> Enum.filter(&(&1 in target_entities))
          |> Enum.map(fn entity_name ->
            graph_edge(source.id, target.id, "entity", 1.0,
              entity_name: entity_name,
              color: "#ffd700",
              line_style: "solid"
            )
          end)
        end)
      end)

    semantic_edges =
      units
      |> Enum.flat_map(fn source ->
        Enum.map(units, fn target ->
          similarity = memory_graph_semantic_weight(source, target)

          if similarity >= @graph_semantic_floor do
            graph_edge(source.id, target.id, "semantic", similarity,
              color: "#ff69b4",
              line_style: "solid"
            )
          end
        end)
      end)
      |> Enum.reject(&is_nil/1)

    temporal_edges =
      units
      |> Enum.flat_map(fn source ->
        Enum.map(units, fn target ->
          if source.id == target.id do
            nil
          else
            case memory_graph_temporal_weight(source, target) do
              nil ->
                nil

              weight ->
                graph_edge(source.id, target.id, "temporal", weight,
                  color: "#00bcd4",
                  line_style: "dashed"
                )
            end
          end
        end)
      end)
      |> Enum.reject(&is_nil/1)

    (entity_edges ++ semantic_edges ++ temporal_edges)
    |> Enum.uniq_by(fn %{"data" => data} -> data["id"] end)
    |> Enum.sort_by(fn %{"data" => data} -> {data["linkType"], data["id"]} end)
    |> Enum.filter(fn %{"data" => data} ->
      Map.has_key?(units_by_id, data["source"]) and Map.has_key?(units_by_id, data["target"])
    end)
  end

  defp graph_edge(source_id, target_id, link_type, weight, opts) do
    %{
      "data" => %{
        "id" => "#{source_id}-#{target_id}-#{link_type}",
        "source" => source_id,
        "target" => target_id,
        "linkType" => link_type,
        "weight" => weight,
        "entityName" => Keyword.get(opts, :entity_name, ""),
        "color" => Keyword.fetch!(opts, :color),
        "lineStyle" => Keyword.fetch!(opts, :line_style)
      }
    }
  end

  defp memory_graph_semantic_weight(source, target) do
    source_vector = memory_unit_vector_list(source)
    target_vector = memory_unit_vector_list(target)

    cond do
      source.id == target.id ->
        1.0

      is_nil(source_vector) or is_nil(target_vector) ->
        0.0

      true ->
        source_vector
        |> cosine_similarity(target_vector)
        |> Float.round(6)
    end
  end

  defp memory_graph_temporal_weight(source, target) do
    source_dt = graph_temporal_anchor(source)
    target_dt = graph_temporal_anchor(target)

    cond do
      is_nil(source_dt) or is_nil(target_dt) ->
        nil

      true ->
        delta_seconds = abs(DateTime.diff(source_dt, target_dt, :second))
        weight = 1.0 / (1.0 + delta_seconds / 86_400)

        if weight >= 0.5 do
          Float.round(weight, 12)
        end
    end
  end

  defp graph_temporal_anchor(unit) do
    unit.occurred_end || unit.occurred_start || unit.occurred_at || unit.mentioned_at
  end

  defp memory_graph_label(text) when is_binary(text) and byte_size(text) > 32 do
    binary_part(text, 0, 29) <> "..."
  end

  defp memory_graph_label(text) when is_binary(text), do: text
  defp memory_graph_label(_text), do: ""

  defp memory_graph_node_color(:observation), do: "#90caf9"
  defp memory_graph_node_color(_fact_type), do: "#42a5f5"

  defp blank_to_na(nil), do: "N/A"
  defp blank_to_na(""), do: "N/A"
  defp blank_to_na(value), do: value

  defp format_graph_table_date(nil), do: nil

  defp format_graph_table_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp memory_graph_chunk_id(%{document_ref: document_ref, metadata: metadata, id: id})
       when is_binary(document_ref) and document_ref != "" do
    metadata["chunk_id"] || id
  end

  defp memory_graph_chunk_id(_unit), do: nil

  defp recall_result_from_item(item, entities, include_chunks) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "type" => item["type"],
      "score" => item["score"],
      "entities" => entities,
      "context" => item["context"],
      "occurred_start" => item["occurred_start"],
      "occurred_end" => item["occurred_end"],
      "mentioned_at" => item["mentioned_at"],
      "document_id" => item["document_id"],
      "source_location" => item["source_location"],
      "metadata" => item["metadata"],
      "chunk_id" => if(include_chunks, do: item["id"], else: nil),
      "tags" => item["tags"],
      "source_fact_ids" => item["source_fact_ids"]
    }
  end

  defp maybe_filter_tag_pattern(items, nil), do: items
  defp maybe_filter_tag_pattern(items, ""), do: items

  defp maybe_filter_tag_pattern(items, pattern) when is_binary(pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> then(&Regex.compile!("^" <> &1 <> "$", "i"))

    Enum.filter(items, fn item -> Regex.match?(regex, item["tag"]) end)
  end

  defp compact_map_preserve_nil(map, preserve_nil_keys) do
    Enum.reduce(map, %{}, fn
      {key, nil}, acc ->
        if key in preserve_nil_keys, do: Map.put(acc, key, nil), else: acc

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp run_reflect_loop(
         ctx,
         payload,
         opts,
         repo,
         repo_opts,
         llm,
         bank_profile,
         directives,
         mental_models,
         recall_result,
         plan,
         initial_plan_prompt,
         observations,
         max_iterations
       ) do
    {expanded_recall_results, expand_tool_call} =
      maybe_expand_reflect_results(
        repo,
        ctx,
        ctx.bank,
        recall_result["results"],
        payload,
        max_iterations,
        repo_opts,
        opts
      )

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
             recall(
               ctx,
               with_reflect_recall_budget(Map.put(payload, "query", plan.focus_query)),
               opts
             ) do
        {expanded_refreshed_results, refreshed_expand_tool_call} =
          maybe_expand_reflect_results(
            repo,
            ctx,
            ctx.bank,
            refreshed_recall["results"],
            payload,
            max_iterations + 2,
            repo_opts,
            opts
          )

        refreshed_recall = Map.put(refreshed_recall, "results", expanded_refreshed_results)
        refreshed_observations = reflect_observations(repo, ctx, payload, opts)

        {:ok,
         %{
           recall_result: refreshed_recall,
           grounded_results:
             merge_grounding_results(
               refreshed_observations["observations"],
               refreshed_recall["results"]
             ),
           observations: refreshed_observations,
           mental_models: active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts),
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
                   "scope_keys" =>
                     ConsolidationPersistence.requested_scope_keys(consolidation_payload(payload)),
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
      else
        {:error, %Error{} = error} ->
          {:error, error}
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
        repo,
        repo_opts,
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
         repo,
         repo_opts,
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
             recall(
               ctx,
               with_reflect_recall_budget(Map.put(payload, "query", plan.focus_query)),
               opts
             ) do
        {expanded_verification_results, verification_expand_tool_call} =
          maybe_expand_reflect_results(
            repo,
            ctx,
            ctx.bank,
            verification_recall["results"],
            payload,
            max_iterations + 1,
            repo_opts,
            opts
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
              repo,
              repo_opts,
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
         repo,
         repo_opts,
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
               llm_call_opts(opts)
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
            {expanded_verification_results, verification_expand_tool_call} =
              maybe_expand_reflect_results(
                repo,
                ctx,
                ctx.bank,
                verification_recall["results"],
                verification_payload,
                next_iteration,
                repo_opts,
                opts
              )

            merged_results =
              merge_reflect_recall_results(
                recall_result["results"],
                expanded_verification_results
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
                    "result_count" => length(expanded_verification_results),
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
                      "result_ids" => Enum.map(expanded_verification_results, & &1["id"]),
                      "evidence_progress" => progress?,
                      "evidence_status" => updated_evidence_discipline["status"]
                    }
                  }
                ] ++ maybe_list(verification_expand_tool_call)

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
                  {expanded_memory_retry_results, memory_retry_expand_tool_call} =
                    maybe_expand_reflect_results(
                      repo,
                      ctx,
                      ctx.bank,
                      memory_retry_recall["results"],
                      memory_retry_payload,
                      next_iteration + 1,
                      repo_opts,
                      opts
                    )

                  memory_retry_merged_results =
                    merge_reflect_recall_results(
                      merged_results,
                      expanded_memory_retry_results
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
                          "result_count" => length(expanded_memory_retry_results),
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
                            "result_ids" => Enum.map(expanded_memory_retry_results, & &1["id"]),
                            "evidence_progress" => memory_retry_progress?,
                            "evidence_status" => memory_retry_evidence_discipline["status"]
                          }
                        }
                      ] ++ maybe_list(memory_retry_expand_tool_call)

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
                  {expanded_memory_retry_results, memory_retry_expand_tool_call} =
                    maybe_expand_reflect_results(
                      repo,
                      ctx,
                      ctx.bank,
                      memory_retry_recall["results"],
                      memory_retry_payload,
                      next_iteration + 1,
                      repo_opts,
                      opts
                    )

                  memory_retry_merged_results =
                    merge_reflect_recall_results(
                      merged_results,
                      expanded_memory_retry_results
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
                          "result_count" => length(expanded_memory_retry_results),
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
                            "result_ids" => Enum.map(expanded_memory_retry_results, & &1["id"]),
                            "evidence_progress" => memory_retry_progress?,
                            "evidence_status" => memory_retry_evidence_discipline["status"]
                          }
                        }
                      ] ++ maybe_list(memory_retry_expand_tool_call)

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
                        {expanded_memory_source_retry_results,
                         memory_source_retry_expand_tool_call} =
                          maybe_expand_reflect_results(
                            repo,
                            ctx,
                            ctx.bank,
                            memory_source_retry_recall["results"],
                            memory_source_retry_payload,
                            next_iteration + 2,
                            repo_opts,
                            opts
                          )

                        memory_source_retry_merged_results =
                          merge_reflect_recall_results(
                            memory_retry_merged_results,
                            expanded_memory_source_retry_results
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
                                "result_count" => length(expanded_memory_source_retry_results),
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
                                    Enum.map(expanded_memory_source_retry_results, & &1["id"]),
                                  "evidence_progress" => memory_source_retry_progress?,
                                  "evidence_status" =>
                                    memory_source_retry_evidence_discipline["status"]
                                }
                              }
                            ] ++ maybe_list(memory_source_retry_expand_tool_call)

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
                  refreshed_observations = reflect_observations(repo, ctx, payload, opts)

                  refreshed_mental_models =
                    active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts)

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
                  {expanded_source_retry_results, source_retry_expand_tool_call} =
                    maybe_expand_reflect_results(
                      repo,
                      ctx,
                      ctx.bank,
                      source_retry_recall["results"],
                      source_retry_payload,
                      next_iteration + 1,
                      repo_opts,
                      opts
                    )

                  source_retry_merged_results =
                    merge_reflect_recall_results(
                      merged_results,
                      expanded_source_retry_results
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
                          "result_count" => length(expanded_source_retry_results),
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
                            "result_ids" => Enum.map(expanded_source_retry_results, & &1["id"]),
                            "evidence_progress" => source_retry_progress?,
                            "evidence_status" => source_retry_evidence_discipline["status"]
                          }
                        }
                      ] ++ maybe_list(source_retry_expand_tool_call)

                  cond do
                    not source_retry_progress? and
                        evidence_breadth_source_consolidation_retry?(
                          available_evidence_discipline,
                          payload,
                          next_iteration + 1,
                          max_iterations
                        ) ->
                      with {:ok, _} <- consolidate(ctx, consolidation_payload(payload), opts) do
                        refreshed_observations = reflect_observations(repo, ctx, payload, opts)

                        refreshed_mental_models =
                          active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts)

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
                                   "scope_keys" => reflect_scope_keys(payload),
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
                refreshed_observations = reflect_observations(repo, ctx, payload, opts)

                refreshed_mental_models =
                  active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts)

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
         repo,
         repo_opts,
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
               llm_call_opts(opts)
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
                 recall(
                   ctx,
                   with_reflect_recall_budget(Map.put(payload, "query", replan.focus_query)),
                   opts
                 ) do
            {expanded_refreshed_results, refreshed_expand_tool_call} =
              maybe_expand_reflect_results(
                repo,
                ctx,
                ctx.bank,
                refreshed_recall["results"],
                payload,
                iteration + 1,
                repo_opts,
                opts
              )

            refreshed_recall = Map.put(refreshed_recall, "results", expanded_refreshed_results)
            refreshed_observations = reflect_observations(repo, ctx, payload, opts)

            {:ok,
             %{
               recall_result: refreshed_recall,
               grounded_results:
                 merge_grounding_results(
                   refreshed_observations["observations"],
                   refreshed_recall["results"]
                 ),
               observations: refreshed_observations,
               mental_models: active_mental_models(repo, ctx, ctx.bank, payload, repo_opts, opts),
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
                       "scope_keys" =>
                         ConsolidationPersistence.requested_scope_keys(
                           consolidation_payload(payload)
                         ),
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
                   recall(
                     ctx,
                     with_reflect_recall_budget(Map.put(payload, "query", replan.focus_query)),
                     opts
                   ) do
              {expanded_verification_results, verification_expand_tool_call} =
                maybe_expand_reflect_results(
                  repo,
                  ctx,
                  ctx.bank,
                  verification_recall["results"],
                  payload,
                  iteration + 1,
                  repo_opts,
                  opts
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
                    repo,
                    repo_opts,
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

  defp maybe_structured_reflect_output(llm, query, text, %{"response_schema" => schema}, opts)
       when is_map(schema) do
    llm.complete_json_schema(
      %{query: query, text: text},
      Foresight.Prompts.Reflect.Structured.V1.messages(query, text, schema),
      schema,
      llm_call_opts(opts)
    )
  end

  defp maybe_structured_reflect_output(_llm, _query, _text, _payload, _opts), do: {:ok, nil}

  defp maybe_rewrite_reflect_text(llm, query, text, payload, opts) when is_binary(text) do
    max_tokens = payload["max_tokens"]

    cond do
      not (is_integer(max_tokens) and max_tokens > 0) ->
        {:ok, text, []}

      true ->
        with {:ok, token_count} <- Budget.count_tokens(text),
             true <- token_count > max_tokens do
          rewrite_reflect_text(llm, query, text, max_tokens, opts)
        else
          false -> {:ok, text, []}
          {:error, _reason} -> {:ok, deterministic_trim_to_tokens(text, max_tokens), []}
        end
    end
  end

  defp maybe_rewrite_reflect_text(_llm, _query, text, _payload, _opts), do: {:ok, text, []}

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
      |> Enum.map(&(&1.external_id || &1["id"]))
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
      MapSet.member?(allowed_ids, model.external_id || model["id"])
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
      |> Enum.filter(&MapSet.member?(model_ids, &1.external_id || &1["id"]))
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
      |> Enum.filter(&MapSet.member?(model_ids, &1.external_id || &1["id"]))
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
      "used_mental_model_ids" => Enum.map(mental_models, &(&1.external_id || &1["id"] || &1[:id]))
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

  defp grounded_support_fingerprint(%Document{} = document) do
    text =
      document.original_text ||
        get_in(document.metadata, ["content"]) ||
        get_in(document.metadata, ["source_query"]) ||
        document.title ||
        document.external_id ||
        ""

    "mental_model:#{normalize_support_text(text)}"
  end

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

          match?(%Document{}, support) ->
            "mental_model:#{support.external_id || support["id"] || inspect(support)}"

          true ->
            "mental_model:#{support["id"] || inspect(support)}"
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

  defp support_source_ids(%Document{metadata: %{"source_fact_ids" => ids}})
       when is_list(ids) and ids != [] do
    ids
  end

  defp support_source_ids(%Document{metadata: %{"source_memory_ids" => ids}})
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

  defp support_document_ids(%Document{} = support, support_index, visited) do
    metadata = support.metadata || %{}
    document_ids = List.wrap(support.external_id)

    case metadata["source_fact_ids"] || metadata["source_memory_ids"] do
      ids when is_list(ids) and ids != [] ->
        (document_ids ++ resolve_source_document_ids(ids, support_index, visited))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        document_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()
    end
  end

  defp support_document_ids(support, support_index, visited) do
    document_ids =
      [support["document_id"]]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    case support_source_ids(support) do
      ids when is_list(ids) and ids != [] ->
        (document_ids ++ resolve_source_document_ids(ids, support_index, visited))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        document_ids |> Enum.uniq()
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
          nil ->
            []

          support ->
            support_document_ids(support, support_index, MapSet.put(visited, id))
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

  defp rewrite_reflect_text(llm, query, text, max_tokens, opts) do
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

    case llm.complete_json_schema(
           %{query: query, text: text},
           messages,
           schema,
           llm_call_opts(opts)
         ) do
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

  defp llm_call_opts(opts) do
    runtime_config = Keyword.get(opts, :resolved_runtime_config, %{})
    role = Keyword.get(opts, :llm_role, :reflect)

    provider_opts =
      runtime_config
      |> runtime_llm_provider_opts(role)
      |> Keyword.merge(Keyword.get(opts, :provider_opts, []))

    opts
    |> Keyword.take([:sleep_ms])
    |> Keyword.put(
      :provider,
      Keyword.get(opts, :provider) || runtime_llm_provider(runtime_config, role)
    )
    |> Keyword.put(:provider_opts, provider_opts)
    |> Enum.reject(fn
      {:provider, nil} -> true
      {:provider_opts, []} -> true
      _other -> false
    end)
  end

  defp consolidation_payload(payload) do
    ConsolidationSupport.consolidation_payload(payload, &reflect_scope_keys/1)
  end

  defp reflect_scope_keys(payload) do
    ConsolidationSupport.reflect_scope_keys(
      payload,
      &ConsolidationPersistence.requested_scope_keys/1
    )
  end

  defp reflect_observations(repo, ctx, payload, opts) do
    with_tenant_scope(ctx, repo, opts, fn ->
      params =
        %{
          "type" => "observation",
          "tags" => payload["tags"],
          "tags_match" => Map.get(payload, "tags_match", "any"),
          "limit" => 5
        }
        |> maybe_put_reflect_scope_filter(payload)

      nested_opts = [repo: repo] ++ Keyword.take(opts, [:rls_enabled])

      case list_memories(ctx, params, nested_opts) do
        {:ok, %{"items" => items}} ->
          state = bank_consolidation_state(repo, ctx.bank, tenant_repo_opts(ctx))

          %{
            "query" => payload["query"],
            "count" => length(items),
            "observations" => Enum.map(items, &observation_item_to_based_on/1),
            "is_stale" => state.pending_consolidation > 0,
            "freshness" => observation_freshness(state.pending_consolidation)
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
    end)
  end

  defp maybe_put_reflect_scope_filter(params, %{"observation_scopes" => scopes})
       when is_map(scopes) do
    Map.put(
      params,
      "scope_keys",
      reflect_scope_keys(%{"observation_scopes" => scopes, "tags" => params["tags"]})
    )
  end

  defp maybe_put_reflect_scope_filter(params, _payload), do: params

  defp observation_item_to_based_on(item) do
    %{
      "id" => item["id"],
      "text" => item["text"] || item["content"],
      "mentioned_at" => item["date"] || item["mentioned_at"],
      "type" => item["type"],
      "source_fact_ids" => item["source_fact_ids"] || []
    }
  end

  defp merge_grounding_results(observations, recall_results) do
    (observations ++ recall_results)
    |> Enum.uniq_by(& &1["id"])
  end

  defp maybe_expand_reflect_results(
         repo,
         ctx,
         bank_id,
         recall_results,
         payload,
         iteration,
         repo_opts,
         opts
       ) do
    with_tenant_scope(ctx, repo, opts, fn ->
      should_expand? =
        to_string(Map.get(payload, "budget", "low")) == "high" and
          Enum.any?(recall_results, &is_binary(&1["document_id"]))

      if should_expand? do
        document_ids =
          recall_results
          |> Enum.map(& &1["document_id"])
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        documents =
          from(document in Document,
            where: document.bank_id == ^bank_id and document.external_id in ^document_ids
          )
          |> repo.all(repo_opts)
          |> Map.new(fn document -> {document.external_id, document} end)

        expanded_results =
          Enum.map(recall_results, fn result ->
            case Map.get(documents, result["document_id"]) do
              %Document{} = document ->
                Map.put(result, "expanded_context", %{
                  "depth" => "document",
                  "document_id" => document.external_id,
                  "document_text" => document.original_text || result["text"]
                })

              nil ->
                result
            end
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
                "depth" => "document"
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
    end)
  end

  defp reflect_max_iterations(payload, opts) do
    base_max_iterations = Keyword.get(opts, :reflect_max_iterations, 10)

    # A missing budget defaults to "mid" (1.0×), NOT "low" (0.5×): use_agentic_reflect?
    # already treats an absent budget as non-low and takes the agentic path, so the
    # loop must get a full iteration allowance. Defaulting to "low" here halved the
    # budget for every default caller, starving the agentic loop into premature
    # exhaustion and canned abstention. Only an explicit "low" throttles to 0.5×.
    multiplier =
      case to_string(Map.get(payload, "budget", "mid")) do
        "low" -> 0.5
        "high" -> 2.0
        _ -> 1.0
      end

    max(1, trunc(base_max_iterations * multiplier))
  end

  defp bank_consolidation_state(repo, bank_id, repo_opts) do
    ConsolidationSupport.bank_consolidation_state(repo, bank_id, repo_opts)
  end

  defp observation_freshness(pending), do: ConsolidationSupport.observation_freshness(pending)

  defp maybe_list(nil), do: []
  defp maybe_list(value), do: [value]

  defp timed_ms(fun) when is_function(fun, 0) do
    started_at_ms = monotonic_ms()
    {fun.(), monotonic_ms() - started_at_ms}
  end

  defp reflect_task_error({%DBConnection.ConnectionError{} = error, _stacktrace}) do
    Error.new(:service_unavailable, %{message: Exception.message(error)})
  end

  defp reflect_task_error({%_{} = error, _stacktrace}) do
    Error.new(:service_unavailable, %{message: Exception.message(error)})
  end

  defp reflect_task_error(reason) do
    Error.new(:service_unavailable, %{message: inspect(reason)})
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp ranked_recall_items(repo, ctx, params, query_embedding, profile, repo_opts, opts) do
    # Once-per-recall: opt into the Python dateparser single-date tail here only.
    temporal_constraint =
      temporal_constraint(params["q"], params["query_timestamp"], dateparser: true)

    strategies = [
      {"semantic",
       fn ->
         semantic_recall_items(repo, ctx, params, query_embedding, profile, repo_opts)
       end},
      {"keyword",
       fn ->
         keyword_recall_items(repo, ctx, params, params["q"], profile, repo_opts)
       end},
      {"graph",
       fn ->
         graph_recall_items(repo, ctx, params, params["q"], query_embedding, profile, repo_opts)
       end},
      {"temporal",
       fn ->
         temporal_recall_items(
           repo,
           ctx,
           params,
           query_embedding,
           profile,
           temporal_constraint,
           repo_opts
         )
       end}
    ]

    {trace, strategy_items} =
      Task.async_stream(
        strategies,
        fn {name, fun} ->
          {name, run_recall_strategy(repo, ctx, fun, opts)}
        end,
        ordered: false,
        timeout: 15_000,
        max_concurrency: 4
      )
      |> Enum.reduce({%{}, %{}}, fn
        {:ok, {name, %{active: active, items: items} = result}}, {trace_acc, merged_acc} ->
          effective_active = active or items != []

          {filtered_items, filter_reason_counts, filtered_records} =
            filter_recall_items(items, params)

          diagnostics =
            result
            |> Map.get(:diagnostics, %{})
            |> Map.put("filtered_out", filtered_records)

          pre_filter_count = length(items)

          merged_acc = Map.put(merged_acc, name, filtered_items)

          trace_acc =
            Map.put(
              trace_acc,
              name,
              %{
                "active" => effective_active,
                "count" => length(filtered_items),
                "pre_filter_count" => pre_filter_count,
                "filtered_out_count" => max(pre_filter_count - length(filtered_items), 0),
                "filtered_out_reason_counts" => filter_reason_counts,
                "contributed" => Enum.map(filtered_items, & &1["id"])
              }
              |> maybe_put_strategy_db_role(result)
              |> maybe_put_strategy_mode(result)
              |> maybe_put_diagnostics(diagnostics)
              |> maybe_put_fully_gated_diagnostics(params["q"] || params["query"] || "")
              |> maybe_put_empty_diagnostics(params["q"] || params["query"] || "")
            )

          {trace_acc, merged_acc}

        {:exit, _reason}, acc ->
          acc
      end)

    fused_strategy_items =
      maybe_add_source_expansion_fusion_strategy(strategy_items)

    items =
      fused_strategy_items
      |> Foresight.Recall.RRF.fuse([k: 60] ++ recall_fusion_opts(params))
      |> Enum.map(fn item ->
        # When a calibrated fusion mode is active, rank by fused_score; :rrf mode
        # carries no fused_score and keeps rrf_score as the authoritative score.
        item
        |> Map.put("score", item["fused_score"] || item["rrf_score"])
        |> Map.put(
          "fusion",
          %{
            "rrf_score" => item["rrf_score"],
            "strategy_contributions" => item["strategy_contributions"]
          }
          |> maybe_put_present("fused_score", item["fused_score"])
          |> maybe_put_present("normalized_score", item["normalized_score"])
        )
      end)

    # `strategy_items` is the 4 real arms; `fused_strategy_items` additionally carries the
    # synthetic source_expansion arm that fusion actually ranks — the relevance-labeling pooler
    # needs the fused set so no candidate fusion sees is silently unlabeled.
    {:ok,
     %{
       items: items,
       strategies: trace,
       strategy_items: strategy_items,
       fused_strategy_items: fused_strategy_items
     }}
  end

  defp run_recall_strategy(repo, ctx, fun, opts) when is_function(fun, 0) do
    Foresight.Tenancy.with_tenant_role(
      ctx,
      fn ->
        result = fun.()
        maybe_put_recall_strategy_db_role(result, repo, ctx)
      end,
      [repo: repo] ++ Keyword.take(opts, [:rls_enabled])
    )
  end

  defp maybe_put_recall_strategy_db_role(result, _repo, %{mode: mode})
       when mode not in [:mode_c],
       do: result

  defp maybe_put_recall_strategy_db_role(result, repo, _ctx) do
    case SQL.query(repo, "SELECT current_role", []) do
      {:ok, %{rows: [[role_name]]}} when is_binary(role_name) ->
        Map.put(result, :db_role, role_name)

      _ ->
        result
    end
  end

  defp maybe_put_strategy_db_role(trace, %{db_role: role_name}) when is_binary(role_name) do
    Map.put(trace, "db_role", role_name)
  end

  defp maybe_put_strategy_db_role(trace, _result), do: trace

  defp trim_recall_items(items, max_tokens) when is_integer(max_tokens) and max_tokens > 0 do
    items
    |> Enum.reduce_while({:ok, {[], 0}}, fn item, {:ok, {kept, used_tokens}} ->
      case recall_item_token_count(item) do
        {:ok, item_tokens} ->
          if used_tokens + item_tokens <= max_tokens do
            {:cont, {:ok, {[item | kept], used_tokens + item_tokens}}}
          else
            # Skip this oversized item and keep scanning — a smaller, equally relevant
            # item later in the ranked list may still fit the budget. Halting here (the
            # old behaviour) truncated recall at the first large hit.
            {:cont, {:ok, {kept, used_tokens}}}
          end

        {:error, reason} ->
          {:halt, {:error, Error.new(:invalid_request, %{message: to_string(reason)})}}
      end
    end)
    |> case do
      {:ok, {[], _used_tokens}} ->
        # No single item fit the budget. Never collapse recall to nothing — return the
        # top-ranked item so the caller always gets the best available evidence.
        {:ok, Enum.take(items, 1)}

      {:ok, {kept, _used_tokens}} ->
        {:ok, Enum.reverse(kept)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp trim_recall_items(items, _max_tokens), do: {:ok, items}

  defp recall_item_token_count(item) do
    item
    |> Map.get("content", Map.get(item, "text", ""))
    |> Budget.count_tokens()
  end

  defp recall_item_token_count_value(item) do
    case recall_item_token_count(item) do
      {:ok, count} -> count
      _ -> nil
    end
  end

  defp recall_trace(
         query,
         params,
         results,
         strategy_trace,
         strategy_items,
         fused_items,
         rerank_candidates,
         reranked_items,
         boosted_items,
         final_items,
         timings_ms
       ) do
    rank_context =
      recall_rank_context(
        fused_items,
        rerank_candidates,
        reranked_items,
        boosted_items,
        final_items
      )

    %{
      "query" => query,
      "num_results" => length(results),
      "time_seconds" => Map.get(timings_ms, "total_ms", 0) / 1000,
      "timings_ms" => timings_ms,
      "strategies" => strategy_trace,
      "entry_points" => recall_entry_points(strategy_items),
      "retrieval_results" => recall_retrieval_results(strategy_items),
      "rrf_merged" => recall_ranked_stage(fused_items, "rrf_score", "rrf", rank_context),
      "rerank_candidates" =>
        recall_ranked_stage(rerank_candidates, "rrf_score", "rerank_candidates", rank_context),
      "reranked" => recall_ranked_stage(reranked_items, "rerank_score", "reranked", rank_context),
      "boosted" => recall_ranked_stage(boosted_items, "boosted_score", "boosted", rank_context),
      "final_results" => recall_final_results(results, rank_context),
      "visits" => recall_visits(final_items, rank_context),
      "summary" =>
        recall_summary(
          params,
          strategy_trace,
          fused_items,
          rerank_candidates,
          reranked_items,
          boosted_items,
          final_items
        ),
      "displacement" => recall_displacement_summary(rank_context, strategy_trace),
      "pruned" =>
        recall_pruned(fused_items, rerank_candidates, reranked_items, boosted_items, final_items),
      "fusion" => recall_trace_fusion(params),
      "reranker" => %{"active" => true, "count" => length(reranked_items)}
    }
  end

  # Was hardcoded to "rrf". Once :normalized became the default that made the
  # trace state the wrong algorithm on every request — the one field an operator would
  # consult to find out what ranking actually ran. Derive it from the same resolver
  # recall itself uses, so the two cannot drift again.
  defp recall_trace_fusion(params) do
    opts = recall_fusion_opts(params)
    base = %{"algorithm" => to_string(Keyword.fetch!(opts, :fusion)), "k" => 60}

    case Keyword.fetch!(opts, :fusion) do
      :rrf -> base
      _ -> Map.put(base, "normalization", to_string(Keyword.fetch!(opts, :normalization)))
    end
  end

  # Surfaced on every synchronous retain result so a consumer can see degradation
  # without attaching to telemetry: fallback_items stored their raw text because
  # extraction errored; empty_items stored it because extraction found no facts.
  # Close the operation's usage ledger; the key is present only when a chargeable
  # call happened, so the Hindsight-shaped result is unchanged for local setups.
  defp maybe_put_usage(response) do
    case Foresight.Usage.report(Foresight.Usage.drain()) do
      nil -> response
      usage -> Map.put(response, "usage", usage)
    end
  end

  defp extraction_report(%{
         enabled: enabled,
         mode: mode,
         fallback_items: fallback_items,
         empty_items: empty_items
       }) do
    %{
      "enabled" => enabled,
      "mode" => mode,
      "fallback_items" => fallback_items,
      "empty_items" => empty_items
    }
  end

  defp retain_result(
         base_result,
         payload,
         extraction_ms,
         runtime_config_ms,
         embedding_profile_ms,
         prepare_memory_units_ms,
         transaction_ms
       ) do
    if payload["trace"] do
      Map.put(base_result, "trace", %{
        "timings_ms" => %{
          "extraction_ms" => extraction_ms,
          "runtime_config_ms" => runtime_config_ms,
          "embedding_profile_ms" => embedding_profile_ms,
          "prepare_memory_units_ms" => prepare_memory_units_ms,
          "transaction_ms" => transaction_ms || 0,
          "total_ms" =>
            extraction_ms + runtime_config_ms + embedding_profile_ms + prepare_memory_units_ms +
              (transaction_ms || 0)
        }
      })
    else
      base_result
    end
  end

  defp recall_entry_points(strategy_items) do
    strategy_items
    |> Enum.reduce(%{}, fn {strategy, items}, acc ->
      items
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

  defp recall_retrieval_results(strategy_items) do
    Map.new(strategy_items, fn {name, items} ->
      {name,
       Enum.with_index(items, 1)
       |> Enum.map(fn {item, rank} ->
         %{
           "node_id" => item["id"],
           "text" => item["content"],
           "rank" => rank,
           "score" => strategy_score(item, name)
         }
         |> Map.merge(recall_trace_evidence(item, name))
       end)}
    end)
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

  defp recall_visits(final_items, rank_context) do
    final_items
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

  defp recall_rank_context(
         fused_items,
         rerank_candidates,
         reranked_items,
         boosted_items,
         final_items
       ) do
    %{
      "rrf" => rank_index(fused_items),
      "rerank_candidates" => rank_index(rerank_candidates),
      "reranked" => rank_index(reranked_items),
      "boosted" => rank_index(boosted_items),
      "final" => rank_index(final_items)
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
         reranked_items,
         boosted_items,
         final_items
       ) do
    %{
      "rrf" => fusion_stage_rollup(fused_items),
      "rerank_candidates" => fusion_stage_rollup(rerank_candidates),
      "reranked" => fusion_stage_rollup(reranked_items),
      "boosted" => fusion_stage_rollup(boosted_items),
      "final" => fusion_stage_rollup(final_items)
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
         reranked_items,
         boosted_items,
         final_items
       ) do
    %{
      "rrf_to_rerank_candidates" => stage_transition_rollup(fused_items, rerank_candidates),
      "rerank_candidates_to_reranked" =>
        stage_transition_rollup(rerank_candidates, reranked_items),
      "reranked_to_boosted" => stage_transition_rollup(reranked_items, boosted_items),
      "boosted_to_final" => stage_transition_rollup(boosted_items, final_items)
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
         params,
         strategy_trace,
         fused_items,
         rerank_candidates,
         reranked_items,
         boosted_items,
         final_items
       ) do
    failure_rollups = failure_rollups(strategy_trace)

    source_expansion =
      source_expansion_summary(
        params,
        strategy_trace,
        fused_items,
        rerank_candidates,
        boosted_items,
        final_items
      )

    %{
      "budget" => Map.get(params, "budget", "mid"),
      "recall_budget" => recall_budget(params),
      "max_tokens" => params["max_tokens"],
      "semantic_similarity_floor" => SemanticFloor.value(params),
      "semantic_fetch_limit" => semantic_fetch_limit(params),
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
          reranked_items,
          boosted_items,
          final_items
        ),
      "source_expansion" => source_expansion,
      "memory_breadth" =>
        memory_breadth_summary(
          params,
          fused_items,
          rerank_candidates,
          boosted_items,
          final_items
        ),
      "evidence_rollups" => evidence_rollups(final_items),
      "final_attribution" => final_attribution(final_items),
      "strategy_evidence_attribution" => strategy_evidence_attribution(final_items),
      "stage_transitions" =>
        stage_transitions(
          fused_items,
          rerank_candidates,
          reranked_items,
          boosted_items,
          final_items
        ),
      "fusion_overlap" => %{
        "single_strategy_candidates" =>
          Enum.count(fused_items, &(map_size(Map.get(&1, "strategy_contributions", %{})) == 1)),
        "multi_strategy_candidates" =>
          Enum.count(fused_items, &(map_size(Map.get(&1, "strategy_contributions", %{})) > 1))
      },
      "rerank_window" => rerank_window_summary(fused_items, rerank_candidates),
      "strategy_wins" => strategy_win_counts(final_items),
      "candidate_count" => length(fused_items),
      "rerank_candidate_count" => length(rerank_candidates),
      "reranked_count" => length(reranked_items),
      "boosted_count" => length(boosted_items),
      "final_count" => length(final_items)
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
         params,
         strategy_trace,
         fused_items,
         rerank_candidates,
         boosted_items,
         final_items
       ) do
    final_ids = MapSet.new(Enum.map(final_items, & &1["id"]))
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))

    %{
      "active" => source_expansion_mode?(params),
      "fused_count" => Enum.count(fused_items, &Map.get(&1, "graph_source_expansion", false)),
      "final_count" => Enum.count(final_items, &Map.get(&1, "graph_source_expansion", false)),
      "frontier" => source_expansion_frontier_summary(fused_items),
      "survivor_count" =>
        Enum.count(
          final_items,
          &Map.has_key?(Map.get(&1, "strategy_contributions", %{}), "source_expansion")
        ),
      "frontier_breadth_survivor_count" =>
        Enum.count(final_items, &source_frontier_breadth_item?/1),
      "exclusive_survivor_count" =>
        Enum.count(final_items, fn item ->
          contributions = Map.get(item, "strategy_contributions", %{})
          map_size(contributions) == 1 and Map.has_key?(contributions, "source_expansion")
        end),
      "boosted_retained_count" =>
        Enum.count(boosted_items, fn item ->
          MapSet.member?(final_ids, item["id"]) and
            Map.has_key?(Map.get(item, "strategy_contributions", %{}), "source_expansion")
        end),
      "boosted_dropped_count" =>
        Enum.count(boosted_items, fn item ->
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
        Enum.count(boosted_items, fn item ->
          not MapSet.member?(final_ids, item["id"]) and
            (get_in(item, ["boosts", "source_expansion_contribution"]) || 0.0) > 0.0
        end),
      "frontier_breadth_trimmed_out_count" =>
        Enum.count(boosted_items, fn item ->
          not MapSet.member?(final_ids, item["id"]) and source_frontier_breadth_item?(item)
        end),
      "novel_only_filtered_count" => source_novel_only_filtered_count(strategy_trace),
      "novel_only_survivor_count" => Enum.count(final_items, &source_novel_only_item?/1),
      "novel_only_boosted_survivor_count" =>
        Enum.count(final_items, fn item ->
          source_novel_only_item?(item) and
            (get_in(item, ["boosts", "source_novel_only_contribution"]) || 0.0) > 0.0
        end),
      "novel_only_exclusive_survivor_count" =>
        Enum.count(final_items, fn item ->
          map_size(Map.get(item, "strategy_contributions", %{})) == 1 and
            source_novel_only_item?(item)
        end),
      "novel_only_boosted_exclusive_survivor_count" =>
        Enum.count(final_items, fn item ->
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
        Enum.count(boosted_items, fn item ->
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

  defp memory_breadth_summary(params, fused_items, rerank_candidates, boosted_items, final_items) do
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))
    final_ids = MapSet.new(Enum.map(final_items, & &1["id"]))

    %{
      "active" => memory_breadth_mode?(params),
      "boosted_count" => Enum.count(boosted_items, &memory_breadth_boosted_item?/1),
      "survivor_count" => Enum.count(final_items, &memory_breadth_boosted_item?/1),
      "windowed_out_count" =>
        Enum.count(fused_items, fn item ->
          not MapSet.member?(rerank_candidate_ids, item["id"]) and
            memory_breadth_boosted_item?(item)
        end),
      "trimmed_out_count" =>
        Enum.count(boosted_items, fn item ->
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

  # Calibrated fusion reads mode + params from the `:recall_fusion` app
  # config. The default is `:normalized`/`:zscore` as measured (+0.1009 nDCG@10,
  # 95% CI [0.0597, 0.1476]) — it was `:rrf` until then. Per-bank tuning layers
  # a bank's learned `config_overrides["recall_fusion"]` on top — that override arrives
  # here through params, put there by apply_runtime_recall_config/3 from the already
  # resolved bank config, so no extra query is issued. A bank without an override resolves
  # to exactly the global layer.
  defp recall_fusion_opts(params) do
    Foresight.Recall.FusionConfig.resolve(
      Application.get_env(:foresight, :recall_fusion, []),
      params["recall_fusion"]
    )
  end

  defp maybe_put_present(map, _key, nil), do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)

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
         reranked_items,
         boosted_items,
         final_items
       ) do
    final_ids = MapSet.new(Enum.map(final_items, & &1["id"]))
    rerank_candidate_ids = MapSet.new(Enum.map(rerank_candidates, & &1["id"]))
    final_count = length(final_items)
    rerank_cutoff_score = rerank_cutoff_score(rerank_candidates)

    %{
      "before_rerank" => length(fused_items),
      "rerank_candidates" => length(rerank_candidates),
      "after_rerank" => length(reranked_items),
      "after_boost" => length(boosted_items),
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
        boosted_items
        |> Enum.reject(&MapSet.member?(final_ids, &1["id"]))
        |> Enum.map(& &1["id"]),
      "dropped_after_trim" =>
        boosted_items
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
      "trim_rollups" => trim_rollups(boosted_items, final_ids)
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

  defp trim_rollups(boosted_items, final_ids) do
    trimmed_items =
      boosted_items
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

  defp prefilter_rerank_candidates(candidates, params) do
    candidates
    |> Enum.sort_by(fn item ->
      {-source_novel_only_priority(item, params), -Map.get(item, "rrf_score", 0.0), item["id"]}
    end)
    |> Enum.take(recall_rerank_window(params))
  end

  defp boost_recall_items(items, params) do
    memory_family_counts = recall_memory_family_counts(items, params)

    items
    |> Enum.map(&apply_recall_boosts(&1, params, memory_family_counts))
    |> Enum.sort_by(fn item ->
      {-source_novel_only_priority(item, params), -Map.get(item, "boosted_score", 0.0),
       -Map.get(item, "rerank_score", 0.0), -Map.get(item, "rrf_score", 0.0), item["id"]}
    end)
  end

  defp source_novel_only_priority(item, params) do
    if source_expansion_novel_only?(params) and source_novel_only_item?(item), do: 1, else: 0
  end

  # The reranker is authoritative. These boosts may only *nudge* its ordering, so the
  # combined multiplier is clamped to @recall_boost_bounds (±25%) — a well-separated
  # pair of rerank scores cannot be flipped by a boost, only near-ties can. Every factor
  # returns 0.5 (neutral) by default; only recency/temporal/proof move on ordinary
  # recall. The remaining factors are dormant unless their explicit verification mode or
  # a generic status:* tag is present. There is deliberately NO query- or content-string
  # matching here (that was the gamed path that let a single corpus phrase 2x a score).
  defp apply_recall_boosts(item, params, memory_family_counts) do
    recency = recall_recency_factor(item, params)
    temporal = recall_temporal_factor(item, params)
    proof = recall_proof_factor(item)
    source_expansion = recall_source_expansion_factor(item)
    source_novel_only = recall_source_novel_only_factor(item, params)
    revision_status = recall_revision_status_factor(item)
    memory_breadth = recall_memory_breadth_factor(item, params, memory_family_counts)

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

  defp recall_memory_family_counts(items, params) do
    if memory_breadth_mode?(params) do
      items
      |> Enum.map(&recall_memory_family_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
    else
      %{}
    end
  end

  defp recall_memory_breadth_factor(item, params, family_counts) do
    cond do
      not memory_breadth_mode?(params) ->
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

  defp recall_source_novel_only_factor(item, params) do
    if source_expansion_novel_only?(params) and source_novel_only_item?(item), do: 1.0, else: 0.5
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

  @doc false
  # Public for unit testing (F5) — the fractional-day recency decay and the
  # occurred_start-only source chain (F2). Pure given item + params.
  def recall_recency_factor(item, params) do
    with %DateTime{} = memory_time <- recall_item_datetime(item),
         %DateTime{} = anchor_time <- recall_anchor_datetime(params) do
      # Fractional days (seconds / 86_400), NOT integer-truncated, faithful to
      # Hindsight's `days_ago = (now - occurred).total_seconds() / 86400`
      # (reranking.py apply_combined_scoring). Linear decay over 365 days,
      # clamped to [0.1, 1.0].
      age_days = max(DateTime.diff(anchor_time, memory_time, :second) / 86_400.0, 0.0)
      max(0.1, min(1.0, 1.0 - age_days / 365.0))
    else
      _ -> 0.5
    end
  end

  defp recall_temporal_factor(item, %{"query_timestamp" => query_timestamp} = params) do
    case temporal_constraint(params["q"], query_timestamp) do
      nil ->
        0.5

      constraint ->
        unit = %{
          occurred_end: parse_datetime(item["occurred_end"]),
          occurred_start: parse_datetime(item["occurred_start"]),
          occurred_at: nil,
          mentioned_at: parse_datetime(item["mentioned_at"])
        }

        temporal_score(unit, constraint, query_timestamp)
    end
  end

  defp recall_temporal_factor(_item, _params), do: 0.5

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

  # A single generic prior over the standard status:* tags — no query- or content-string
  # inspection, no intent classification. It complements the stored
  # supersession edges: it demotes tags a consolidation pass may set (superseded/stale)
  # and mildly favours corrected/latest facts. Weighted at α=0.2 so it can only nudge.
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

  defp recall_anchor_datetime(_params), do: DateTime.utc_now()

  # Recency reads occurred_start ONLY, faithful to Hindsight's apply_combined_scoring
  # (search/reranking.py:103): a memory with no explicit event start gets neutral
  # recency (0.5), NOT a boost derived from occurred_end/mentioned_at (F2).
  defp recall_item_datetime(item) do
    parse_datetime(item["occurred_start"])
  end

  defp strategy_score(item, "semantic"), do: Map.get(item, "semantic_score", 0.0)
  defp strategy_score(item, "keyword"), do: Map.get(item, "keyword_score", 0.0)
  defp strategy_score(item, "graph"), do: Map.get(item, "graph_score", 0.0)
  defp strategy_score(item, "temporal"), do: Map.get(item, "temporal_score", 0.0)
  defp strategy_score(_item, _name), do: 0.0

  defp apply_recall_boost_multiplier(score, multiplier)
       when is_number(score) and is_number(multiplier) and score < 0.0 do
    score / max(multiplier, 1.0e-6)
  end

  defp apply_recall_boost_multiplier(score, multiplier)
       when is_number(score) and is_number(multiplier) do
    score * multiplier
  end

  @doc false
  # Public for unit testing (F3). Faithful to Hindsight's native tsvector
  # path (sql/postgresql.py joins raw tokens with `|`, no prefix): OR-join the
  # tokens WITHOUT `:*` prefix matching, so the keyword arm is no more permissive
  # than Hindsight's (e.g. "run" does not match "running").
  def keyword_tsquery(query) when is_binary(query) do
    query
    |> keyword_terms()
    |> Enum.join(" | ")
  end

  @doc false
  # Public for unit testing — a pure tokenizer with no side effects. Guards the
  # the fidelity fix against a future stopword-list regression.
  def keyword_terms(query) when is_binary(query) do
    # Faithful to Hindsight (tokenize_query + prepare_bm25_text): strip
    # punctuation, lowercase, split on non-word runs, OR-join for
    # to_tsquery('english'). Stopword removal is delegated ENTIRELY to Postgres's
    # english text-search config — we keep NO custom stopword list and no minimum
    # length filter. The old list wrongly stripped meaningful terms (real, reason,
    # simply, was, not) before to_tsquery, silently shrinking keyword recall.
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.uniq()
  end

  defp recall_base_query(ctx, params, profile) do
    vector_field = profile["vector_field"]

    from(unit in MemoryUnit,
      # Superseded observations are retained (with a `supersedes` edge)
      # for history/audit but excluded from active recall, so stale facets never
      # resurface — the non-destructive counterpart to Hindsight's hard-delete.
      where:
        unit.bank_id == ^ctx.bank and
          unit.embedded_dim == ^profile["embedding_dim"] and
          unit.embedded_by == ^profile["model_id"] and
          not is_nil(field(unit, ^vector_field)) and
          is_nil(unit.superseded_at)
    )
    |> maybe_filter_type(params["type"] || first_type(params["types"]))
  end

  defp memory_unit_to_recall_response(memory_unit, query_embedding) do
    %{
      "id" => memory_unit.id,
      "content" => memory_unit.content,
      "score" => recall_score(memory_unit, query_embedding),
      "type" => Atom.to_string(memory_unit.fact_type),
      "context" => memory_unit.context,
      "occurred_start" => format_datetime(memory_unit.occurred_start || memory_unit.occurred_at),
      "occurred_end" => format_datetime(memory_unit.occurred_end || memory_unit.occurred_at),
      "mentioned_at" => format_datetime(memory_unit.mentioned_at),
      "document_id" => memory_unit.document_ref,
      "source_location" => memory_unit.source_location,
      "metadata" => memory_unit.metadata,
      "tags" => memory_unit.tags,
      "source_fact_ids" => Enum.map(memory_unit.source_memory_ids || [], &to_string/1),
      "proof_count" => memory_unit.proof_count || 1
    }
  end

  defp semantic_recall_items(repo, ctx, params, query_embedding, profile, repo_opts) do
    vector_field = profile["vector_field"]
    query_vector = EmbeddingProfile.to_vector(vector_field, query_embedding)

    fetched_items =
      ctx
      |> recall_base_query(params, profile)
      |> where_similarity_at_least(vector_field, query_vector, SemanticFloor.value(params))
      |> order_by([unit], cosine_distance(field(unit, ^vector_field), ^query_vector))
      |> limit(^semantic_fetch_limit(params))
      |> repo.all(repo_opts)
      |> Enum.map(&memory_unit_to_recall_response(&1, query_embedding))
      |> Enum.map(&put_strategy_score(&1, "semantic_score", &1["score"]))

    items = select_semantic_candidates(fetched_items, params)
    selected_ids = MapSet.new(Enum.map(items, & &1["id"]))

    diagnostics = %{
      "gated_out" => [],
      "capped_out" =>
        fetched_items
        |> Enum.reject(&MapSet.member?(selected_ids, &1["id"]))
        |> Enum.take(5)
        |> Enum.map(&gate_record(&1, "semantic_score", "semantic_candidate_cap"))
    }

    %{active: true, items: items, diagnostics: diagnostics}
  end

  defp select_semantic_candidates(items, params) do
    limit = semantic_candidate_limit(params)

    if memory_breadth_mode?(params) do
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

  defp keyword_recall_items(repo, ctx, params, query, profile, repo_opts) do
    keyword_query = keyword_tsquery(query)

    fetched_items =
      ctx
      |> recall_base_query(params, profile)
      # Reference the STORED, generated `search_tsv` column (an exact materialisation of
      # to_tsvector('english', content || ' ' || context)) instead of recomputing the
      # vector per row. This makes the existing GIN index on search_tsv usable — the
      # inline to_tsvector could never hit it — turning a full scan into an index scan.
      |> where(
        [unit],
        fragment("search_tsv @@ to_tsquery('english', ?)", ^keyword_query)
      )
      |> order_by(
        [unit],
        desc: fragment("ts_rank_cd(search_tsv, to_tsquery('english', ?))", ^keyword_query)
      )
      |> limit(^(recall_budget(params) + 5))
      |> repo.all(repo_opts)
      |> Enum.map(fn unit ->
        unit
        |> memory_unit_to_recall_response([])
        |> put_strategy_score("keyword_score", keyword_score(unit, query))
      end)

    items = Enum.take(fetched_items, recall_budget(params))

    diagnostics = %{
      "gated_out" => [],
      "capped_out" =>
        fetched_items
        |> Enum.drop(recall_budget(params))
        |> Enum.take(5)
        |> Enum.map(&gate_record(&1, "keyword_score", "keyword_candidate_cap"))
    }

    %{active: true, items: items, diagnostics: diagnostics}
  end

  defp graph_recall_items(repo, ctx, params, query, query_embedding, profile, repo_opts) do
    entity_names =
      query
      |> Foresight.EntityExtractors.Simple.extract()
      |> Enum.map(&normalize_entity_name/1)

    source_expansion? = source_expansion_mode?(params)
    source_shortfall_type = source_expansion_shortfall_type(params)

    {items, diagnostics} =
      cond do
        entity_names == [] and not source_expansion? ->
          {[],
           %{
             "inactive" => [inactive_record(query, "graph_no_entity_seed")],
             "gated_out" => [
               inactive_record(query, "graph_no_entity_seed")
             ],
             "capped_out" => []
           }}

        true ->
          entity_seed_units =
            if entity_names == [] do
              []
            else
              from(unit in MemoryUnit,
                join: link in MemoryUnitEntity,
                on: link.memory_unit_id == unit.id,
                join: entity in Entity,
                on: entity.id == link.entity_id,
                where:
                  unit.bank_id == ^ctx.bank and
                    unit.embedded_dim == ^profile["embedding_dim"] and
                    unit.embedded_by == ^profile["model_id"] and
                    entity.normalized_name in ^entity_names,
                distinct: unit.id
              )
              |> maybe_filter_type(params["type"] || first_type(params["types"]))
              |> limit(^recall_budget(params))
              |> repo.all(repo_opts)
            end

          source_seed_units =
            if source_expansion? do
              source_expansion_seed_units(
                repo,
                ctx,
                params,
                query_embedding,
                profile,
                source_shortfall_type,
                repo_opts
              )
            else
              []
            end

          direct_units =
            (entity_seed_units ++ source_seed_units)
            |> Enum.uniq_by(& &1.id)

          source_seed_ids = source_seed_units |> Enum.map(& &1.id) |> MapSet.new()

          source_expansion_context =
            source_expansion_context(direct_units, source_seed_ids)

          {graph_units, frontier_filtered_out} =
            graph_traversal_units(
              repo,
              ctx,
              params,
              direct_units,
              source_seed_ids,
              query_embedding,
              source_expansion_context,
              source_shortfall_type,
              repo_opts
            )

          seed_ids = Enum.map(direct_units, & &1.id)

          # Read the stored semantic-link graph: a single
          # batched lookup of seed<->candidate edge weights, so graph_score can
          # reward candidates that the precomputed kNN graph converges on — a
          # signal independent of the semantic arm's direct query->unit similarity.
          stored_link_scores =
            stored_link_scores(
              repo,
              ctx.bank,
              "semantic",
              seed_ids,
              Enum.map(graph_units, & &1.unit.id),
              repo_opts
            )

          scored_items =
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
              source_seed? = MapSet.member?(source_seed_ids, unit.id)
              stored_link_score = Map.get(stored_link_scores, unit.id, 0.0)

              score =
                graph_score(
                  unit,
                  entity_names,
                  seed_ids,
                  query_embedding,
                  hop,
                  seed_overlap,
                  source_seed?,
                  source_overlap_count,
                  source_shortfall_bonus,
                  stored_link_score
                )

              item =
                unit
                |> memory_unit_to_recall_response(query_embedding)
                |> Map.put("graph_stored_link_score", stored_link_score)
                |> Map.put("graph_hop", hop)
                |> Map.put("graph_seed_overlap_count", length(seed_overlap))
                |> Map.put("graph_frontier_overlap_count", frontier_overlap_count)
                |> Map.put("graph_source_seed", source_seed?)
                |> Map.put("graph_source_overlap_count", source_overlap_count)
                |> Map.put("graph_source_traversal_score", source_traversal_score)
                |> Map.put("graph_source_shortfall_bonus", source_shortfall_bonus)
                |> Map.put("graph_source_frontier_group", frontier_evidence["group"])
                |> Map.put(
                  "graph_source_frontier_novel_count",
                  frontier_evidence["novel_count"] || 0
                )
                |> Map.put("graph_source_frontier_priority", frontier_evidence["priority"])
                |> put_strategy_score("graph_score", score)

              if source_expansion? do
                Map.put(item, "graph_source_expansion", true)
                |> Map.put("graph_source_shortfall_type", source_shortfall_type)
              else
                item
              end
            end)
            |> Enum.sort_by(fn item -> {-Map.get(item, "graph_score", 0.0), item["id"]} end)

          items = Enum.take(scored_items, recall_budget(params))

          diagnostics =
            %{
              "gated_out" => [],
              "capped_out" =>
                scored_items
                |> Enum.drop(recall_budget(params))
                |> Enum.take(5)
                |> Enum.map(&gate_record(&1, "graph_score", "graph_candidate_cap"))
            }
            |> maybe_put_frontier_filtered_out(frontier_filtered_out)
            |> maybe_put_source_expansion_empty_diagnostics(
              query,
              source_expansion?,
              direct_units
            )

          {items, diagnostics}
      end

    %{
      active: entity_names != [] or source_expansion?,
      items: items,
      diagnostics: diagnostics,
      source_expansion: source_expansion?
    }
  end

  defp source_expansion_seed_units(
         repo,
         ctx,
         params,
         query_embedding,
         profile,
         source_shortfall_type,
         repo_opts
       ) do
    fetch_limit = source_expansion_seed_fetch_limit(params, source_shortfall_type)
    selection_limit = source_expansion_seed_limit(params, source_shortfall_type)
    vector_field = profile["vector_field"]
    query_vector = EmbeddingProfile.to_vector(vector_field, query_embedding)

    from(unit in MemoryUnit,
      where:
        unit.bank_id == ^ctx.bank and
          unit.embedded_dim == ^profile["embedding_dim"] and
          unit.embedded_by == ^profile["model_id"] and
          not is_nil(field(unit, ^vector_field)) and
          fragment("array_length(?, 1) > 0", unit.source_memory_ids)
    )
    |> where_similarity_at_least(vector_field, query_vector, @temporal_similarity_floor)
    |> maybe_filter_type(params["type"] || first_type(params["types"]))
    |> order_by([unit], cosine_distance(field(unit, ^vector_field), ^query_vector))
    |> limit(^fetch_limit)
    |> repo.all(repo_opts)
    |> prioritize_source_expansion_seeds(query_embedding, source_shortfall_type)
    |> Enum.take(selection_limit)
  end

  defp graph_traversal_units(
         _repo,
         _ctx,
         _params,
         [],
         _source_seed_ids,
         _query_embedding,
         _source_expansion_context,
         _source_shortfall_type,
         _repo_opts
       ),
       do: {[], []}

  defp graph_traversal_units(
         repo,
         ctx,
         params,
         direct_units,
         source_seed_ids,
         query_embedding,
         source_expansion_context,
         source_shortfall_type,
         repo_opts
       ) do
    budget = recall_budget(params)
    source_expansion? = source_expansion_mode?(params)
    source_novel_only? = source_expansion_novel_only?(params)

    seeds =
      direct_units
      |> Enum.uniq_by(& &1.id)
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
          seed_overlap: [unit.id],
          frontier_overlap_count: 1,
          source_seed_overlap_count: if(MapSet.member?(source_seed_ids, unit.id), do: 1, else: 0),
          source_traversal_score: 0.0,
          source_shortfall_bonus: 0.0,
          frontier_evidence: frontier_evidence
        }
      end)

    seed_ids = MapSet.new(Enum.map(seeds, & &1.unit.id))

    {visited, _frontier, frontier_filtered_out} =
      Enum.reduce_while(1..@graph_max_hops, {seeds, seeds, []}, fn hop,
                                                                   {visited, frontier,
                                                                    filtered_out} ->
        frontier_ids = Enum.map(frontier, & &1.unit.id)
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
              from(unit in MemoryUnit,
                where:
                  unit.bank_id == ^ctx.bank and
                    fragment(
                      "? && ?",
                      unit.source_memory_ids,
                      type(^frontier_ids, {:array, :binary_id})
                    )
              )
              |> maybe_filter_type(params["type"] || first_type(params["types"]))
              |> limit(^fetch_limit)
              |> repo.all(repo_opts)
              |> Enum.reject(fn unit ->
                Enum.any?(visited, &(&1.unit.id == unit.id))
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
              |> Enum.map(fn unit ->
                frontier_overlap =
                  unit.source_memory_ids
                  |> List.wrap()
                  |> Enum.filter(&(&1 in frontier_ids))

                seed_overlap =
                  unit.source_memory_ids
                  |> List.wrap()
                  |> Enum.filter(fn source_id ->
                    MapSet.member?(seed_ids, source_id)
                  end)

                source_seed_overlap_count =
                  unit.source_memory_ids
                  |> List.wrap()
                  |> Enum.count(&MapSet.member?(source_seed_ids, &1))

                source_traversal_score =
                  if source_expansion? do
                    source_expansion_traversal_score(
                      unit,
                      query_embedding,
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

  defp source_expansion_novel_candidate?(memory_unit, source_seed_ids) do
    memory_unit.source_memory_ids
    |> List.wrap()
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
      "node_id" => unit.id,
      "text" => unit.content,
      "score" => 0.0,
      "reasons" => ["source_novel_only_filter"],
      "reason" => "source_novel_only_filter",
      "evidence" => %{
        "hop" => hop,
        "source_seed_overlap_count" =>
          unit.source_memory_ids
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

  defp temporal_recall_items(
         repo,
         ctx,
         params,
         query_embedding,
         profile,
         temporal_constraint,
         repo_opts
       ) do
    {items, diagnostics} =
      if is_nil(temporal_constraint) do
        {[],
         %{
           "inactive" => [
             inactive_record(params["q"] || params["query"] || "", "no_temporal_constraint")
           ]
         }}
      else
        entry_units =
          ctx
          |> recall_base_query(params, profile)
          |> maybe_filter_temporal_constraint(temporal_constraint)
          |> order_by([unit], desc: unit.mentioned_at, desc: unit.inserted_at)
          |> limit(^temporal_entry_point_limit(params))
          |> repo.all(repo_opts)

        raw_entry_items =
          entry_units
          |> Enum.map(fn unit ->
            item = memory_unit_to_recall_response(unit, query_embedding)

            {unit,
             item
             |> Map.put("temporal_hop", 0)
             |> Map.put("temporal_semantic_score", item["score"])}
          end)

        entry_items =
          raw_entry_items
          |> Enum.filter(fn {_unit, item} ->
            Map.get(item, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor
          end)
          |> Enum.sort_by(fn {_unit, item} ->
            {-Map.get(item, "temporal_semantic_score", 0.0), item["id"]}
          end)
          |> Enum.take(temporal_result_limit(params))

        traversal_items =
          temporal_traversal_items(
            repo,
            ctx,
            params,
            query_embedding,
            temporal_constraint,
            entry_items,
            repo_opts
          )

        temporal_candidates =
          (entry_items ++ traversal_items)
          |> Enum.uniq_by(fn {_unit, item} -> item["id"] end)

        # Read the stored temporal-link graph: strongest
        # temporal edge weight between each candidate and the temporal entry seeds,
        # so proximity structure computed at retain time contributes to the score
        # rather than being re-derived only from source_memory_ids lineage.
        temporal_stored_scores =
          stored_link_scores(
            repo,
            ctx.bank,
            "temporal",
            Enum.map(entry_items, fn {unit, _item} -> unit.id end),
            Enum.map(temporal_candidates, fn {unit, _item} -> unit.id end),
            repo_opts
          )

        kept_items =
          temporal_candidates
          |> Enum.map(fn {unit, item} ->
            item
            |> Map.put(
              "temporal_stored_link_score",
              Map.get(temporal_stored_scores, unit.id, 0.0)
            )
            |> then(fn item ->
              put_strategy_score(
                item,
                "temporal_score",
                temporal_runtime_score(unit, item, temporal_constraint, params["query_timestamp"])
              )
            end)
          end)
          |> Enum.sort_by(fn item -> {-Map.get(item, "temporal_score", 0.0), item["id"]} end)
          |> Enum.take(recall_budget(params))

        diagnostics = %{
          "gated_out" =>
            raw_entry_items
            |> Enum.reject(fn {_unit, item} ->
              Map.get(item, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor
            end)
            |> Enum.take(5)
            |> Enum.map(fn {_unit, item} ->
              gate_record(item, "temporal_semantic_score", "temporal_similarity_floor")
            end),
          "capped_out" =>
            raw_entry_items
            |> Enum.filter(fn {_unit, item} ->
              Map.get(item, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor
            end)
            |> Enum.sort_by(fn {_unit, item} ->
              {-Map.get(item, "temporal_semantic_score", 0.0), item["id"]}
            end)
            |> Enum.drop(temporal_result_limit(params))
            |> Enum.take(5)
            |> Enum.map(fn {_unit, item} ->
              gate_record(item, "temporal_semantic_score", "temporal_entry_cap")
            end)
        }

        {kept_items, diagnostics}
      end

    %{active: not is_nil(temporal_constraint), items: items, diagnostics: diagnostics}
  end

  defp temporal_traversal_items(
         _repo,
         _ctx,
         _params,
         _query_embedding,
         _constraint,
         [],
         _repo_opts
       ),
       do: []

  defp temporal_traversal_items(
         repo,
         ctx,
         params,
         query_embedding,
         _temporal_constraint,
         entry_items,
         repo_opts
       ) do
    entry_by_id = Map.new(entry_items, fn {unit, item} -> {unit.id, {unit, item}} end)
    seed_ids = Map.keys(entry_by_id) |> MapSet.new()
    budget = recall_budget(params)

    frontier =
      Enum.map(entry_items, fn {unit, item} ->
        %{unit: unit, item: item, hop: 0}
      end)

    visited_ids = MapSet.new(Map.keys(entry_by_id))

    {visited, _frontier, _visited_ids} =
      Enum.reduce_while(1..@temporal_max_hops, {[], frontier, visited_ids}, fn hop,
                                                                               {visited, frontier,
                                                                                visited_ids} ->
        frontier_ids = Enum.map(frontier, & &1.unit.id)
        remaining_budget = max(budget - length(entry_items) - length(visited), 0)

        cond do
          frontier_ids == [] or remaining_budget == 0 ->
            {:halt, {visited, frontier, visited_ids}}

          true ->
            next_frontier =
              from(unit in MemoryUnit,
                where:
                  unit.bank_id == ^ctx.bank and
                    fragment(
                      "? && ?",
                      unit.source_memory_ids,
                      type(^frontier_ids, {:array, :binary_id})
                    )
              )
              |> maybe_filter_type(params["type"] || first_type(params["types"]))
              |> limit(^(temporal_result_limit(params) * @temporal_per_source_limit))
              |> repo.all(repo_opts)
              |> Enum.reject(&MapSet.member?(visited_ids, &1.id))
              |> Enum.map(fn unit ->
                source_overlap =
                  unit.source_memory_ids
                  |> List.wrap()
                  |> Enum.filter(fn source_id ->
                    source_id in frontier_ids or MapSet.member?(seed_ids, source_id)
                  end)

                best_seed_score =
                  source_overlap
                  |> Enum.map(fn source_id ->
                    case Map.fetch(entry_by_id, source_id) do
                      {:ok, {_seed_unit, seed_item}} ->
                        Map.get(
                          seed_item,
                          "temporal_seed_score",
                          Map.get(seed_item, "score", 0.0)
                        )

                      :error ->
                        frontier
                        |> Enum.find_value(0.0, fn frontier_item ->
                          if frontier_item.unit.id == source_id,
                            do: Map.get(frontier_item.item, "temporal_seed_score", 0.0),
                            else: nil
                        end)
                    end
                  end)
                  |> Enum.max(fn -> 0.0 end)

                item =
                  unit
                  |> memory_unit_to_recall_response(query_embedding)
                  |> Map.put(
                    "temporal_semantic_score",
                    Map.get(memory_unit_to_recall_response(unit, query_embedding), "score", 0.0)
                  )
                  |> Map.put("temporal_hop", hop)
                  |> Map.put("temporal_source_overlap", source_overlap)
                  |> Map.put("temporal_overlap_bonus", min(length(source_overlap), 3) * 0.05)
                  |> Map.put(
                    "temporal_seed_score",
                    Float.round(best_seed_score * @temporal_decay, 6)
                  )

                %{unit: unit, item: item, hop: hop}
              end)
              |> Enum.filter(fn %{item: item} ->
                Map.get(item, "temporal_semantic_score", 0.0) >= @temporal_similarity_floor
              end)
              |> Enum.sort_by(fn %{unit: unit, item: item} ->
                {-Map.get(item, "temporal_seed_score", 0.0),
                 -Map.get(item, "temporal_semantic_score", 0.0), unit.id}
              end)
              |> Enum.take(
                min(remaining_budget, temporal_result_limit(params) * @temporal_per_source_limit)
              )

            next_visited_ids =
              Enum.reduce(next_frontier, visited_ids, fn %{unit: unit}, acc ->
                MapSet.put(acc, unit.id)
              end)

            next_visited =
              next_frontier
              |> Enum.map(fn %{unit: unit, item: item} -> {unit, item} end)

            {:cont, {visited ++ next_visited, next_frontier, next_visited_ids}}
        end
      end)

    visited
    |> Enum.sort_by(fn {unit, item} ->
      {-Map.get(item, "temporal_seed_score", 0.0), -Map.get(item, "temporal_semantic_score", 0.0),
       unit.id}
    end)
    |> Enum.take(temporal_result_limit(params))
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, type) do
    normalized = normalize_fact_type(type)
    from(unit in query, where: unit.fact_type == ^normalized)
  end

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, term) do
    like = "%#{term}%"
    from(unit in query, where: ilike(unit.content, ^like) or ilike(unit.context, ^like))
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, []), do: query

  defp maybe_filter_tags(query, tags) when is_list(tags) do
    from(unit in query, where: fragment("? && CAST(? AS text[])", unit.tags, ^tags))
  end

  defp maybe_filter_tags_match(query, _tags, nil), do: query
  defp maybe_filter_tags_match(query, nil, _mode), do: query
  defp maybe_filter_tags_match(query, [], _mode), do: query

  defp maybe_filter_tags_match(query, tags, mode) when mode in ["all", "all_strict"] do
    from(unit in query, where: fragment("? @> CAST(? AS text[])", unit.tags, ^tags))
  end

  defp maybe_filter_tags_match(query, _tags, _mode), do: query

  defp maybe_filter_document_id(query, nil), do: query
  defp maybe_filter_document_id(query, ""), do: query

  defp maybe_filter_document_id(query, document_id) when is_binary(document_id) do
    from(unit in query, where: unit.document_ref == ^document_id)
  end

  defp maybe_filter_chunk_id(query, nil), do: query
  defp maybe_filter_chunk_id(query, ""), do: query

  defp maybe_filter_chunk_id(query, chunk_id) when is_binary(chunk_id) do
    from(unit in query, where: unit.id == ^chunk_id)
  end

  defp filter_recall_items(items, params) do
    question_date = parse_query_timestamp(params["query_timestamp"])

    Enum.reduce(items, {[], %{}, []}, fn item, {kept, reason_counts, filtered_records} ->
      tag_match? = match_recall_tags?(item["tags"], params)
      timestamp_match? = match_query_timestamp?(item, question_date)
      source_linked_match? = match_source_linked_only?(item, params)

      case {tag_match?, timestamp_match?, source_linked_match?} do
        {true, true, true} ->
          {[item | kept], reason_counts, filtered_records}

        _ ->
          reasons =
            []
            |> maybe_add_filter_reason(not tag_match?, "tag_filter")
            |> maybe_add_filter_reason(not timestamp_match?, "query_timestamp_filter")
            |> maybe_add_filter_reason(not source_linked_match?, "source_linked_filter")

          updated_counts =
            Enum.reduce(reasons, reason_counts, fn reason, acc ->
              Map.update(acc, reason, 1, &(&1 + 1))
            end)

          record =
            %{
              "node_id" => item["id"],
              "text" => item["text"] || item["content"],
              "score" => item["score"] || 0.0,
              "reasons" => Enum.sort(reasons)
            }

          {kept, updated_counts, [record | filtered_records]}
      end
    end)
    |> then(fn {kept, reason_counts, filtered_records} ->
      {Enum.reverse(kept), reason_counts, Enum.reverse(filtered_records) |> Enum.take(5)}
    end)
  end

  defp maybe_add_filter_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_filter_reason(reasons, false, _reason), do: reasons

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

  # Fail closed: a non-empty `tags` filter with no explicit `tags_match` must
  # still scope by any-overlap. Without this clause the catch-all below returns
  # true and DISABLES tag filtering, leaking rows across sub-bank tag scopes for
  # any caller that passes tags without tags_match (reflect pre-seed, tool_recall,
  # search_observations). (security audit.)
  # Fail closed: a non-empty `tags` filter with no explicit `tags_match` must
  # still scope by any-overlap. Without this clause the catch-all below returns
  # true and DISABLES tag filtering, leaking rows across sub-bank tag scopes for
  # any caller that passes tags without tags_match (reflect pre-seed, tool_recall,
  # search_observations). (security audit.)
  defp match_recall_tags?(tags, %{"tags" => requested})
       when is_list(requested) and requested != [] do
    match_tag_list?(tags, requested, "any")
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

  defp match_query_timestamp?(_item, nil), do: true

  defp match_query_timestamp?(item, %DateTime{} = question_date) do
    timestamp =
      item["mentioned_at"] || item["occurred_end"] || item["occurred_start"]

    case parse_datetime(timestamp) do
      nil -> true
      mentioned_at -> DateTime.compare(mentioned_at, question_date) != :gt
    end
  end

  defp match_source_linked_only?(item, %{"source_linked_only" => true} = params) do
    source_expansion_mode?(params) and
      List.wrap(item["source_fact_ids"] || item["source_memory_ids"]) != []
  end

  defp match_source_linked_only?(_item, _params), do: true

  defp maybe_filter_after(query, nil), do: query

  defp maybe_filter_after(query, %DateTime{} = after_datetime) do
    from(unit in query, where: unit.mentioned_at >= ^after_datetime)
  end

  defp maybe_filter_after(query, value) do
    case parse_datetime(value) do
      nil -> query
      datetime -> maybe_filter_after(query, datetime)
    end
  end

  defp maybe_filter_before(query, nil), do: query

  defp maybe_filter_before(query, %DateTime{} = before_datetime) do
    from(unit in query, where: unit.mentioned_at <= ^before_datetime)
  end

  defp maybe_filter_before(query, value) do
    case parse_datetime(value) do
      nil -> query
      datetime -> maybe_filter_before(query, datetime)
    end
  end

  defp maybe_filter_audit_action(query, nil), do: query
  defp maybe_filter_audit_action(query, ""), do: query

  defp maybe_filter_audit_action(query, action) when is_binary(action) do
    from(audit_log in query, where: audit_log.action == ^action)
  end

  defp maybe_filter_audit_transport(query, nil), do: query
  defp maybe_filter_audit_transport(query, ""), do: query

  defp maybe_filter_audit_transport(query, transport) when is_binary(transport) do
    from(audit_log in query, where: audit_log.transport == ^transport)
  end

  defp maybe_filter_audit_started_at_gte(query, nil), do: query

  defp maybe_filter_audit_started_at_gte(query, %DateTime{} = started_at) do
    from(audit_log in query, where: audit_log.started_at >= ^started_at)
  end

  defp maybe_filter_audit_started_at_gte(query, value) do
    case parse_datetime(value) do
      nil -> query
      datetime -> maybe_filter_audit_started_at_gte(query, datetime)
    end
  end

  defp maybe_filter_audit_started_at_lt(query, nil), do: query

  defp maybe_filter_audit_started_at_lt(query, %DateTime{} = started_at) do
    from(audit_log in query, where: audit_log.started_at < ^started_at)
  end

  defp maybe_filter_audit_started_at_lt(query, value) do
    case parse_datetime(value) do
      nil -> query
      datetime -> maybe_filter_audit_started_at_lt(query, datetime)
    end
  end

  defp maybe_filter_temporal_constraint(query, %{
         from: %DateTime{} = from_dt,
         to: %DateTime{} = to_dt
       }) do
    from(unit in query,
      where:
        fragment(
          "coalesce(?, ?, ?) >= ?",
          unit.occurred_start,
          unit.occurred_at,
          unit.mentioned_at,
          ^from_dt
        ) and
          fragment(
            "coalesce(?, ?, ?) <= ?",
            unit.occurred_end,
            unit.occurred_at,
            unit.mentioned_at,
            ^to_dt
          )
    )
  end

  defp maybe_filter_temporal_constraint(query, _constraint), do: query

  defp maybe_filter_min_score(items, nil), do: items

  defp maybe_filter_min_score(items, min_score) when is_number(min_score) do
    Enum.filter(items, &((&1["score"] || 0.0) >= min_score))
  end

  defp maybe_filter_min_score(items, _min_score), do: items

  # The recall score is the reranker's calibrated score after boosts, so a cutoff is
  # meaningful on it; it is applied after boosting and before the token trim, so the
  # trim never spends budget on results the caller would discard.
  defp validate_min_score(nil), do: :ok
  defp validate_min_score(value) when is_number(value) and value >= 0, do: :ok

  defp validate_min_score(_value) do
    {:error, Error.new(:invalid_request, %{message: "min_score must be a non-negative number"})}
  end

  defp normalize_recall_payload(payload) do
    case Enum.find(@unsupported_recall_fields, &Map.has_key?(payload, &1)) do
      nil ->
        with :ok <- validate_tag_filters(payload),
             :ok <- validate_query_timestamp(payload["query_timestamp"]),
             :ok <- validate_min_score(payload["min_score"]) do
          payload
          |> Map.take([
            "budget",
            "max_tokens",
            "min_score",
            "query_timestamp",
            "source_linked_only",
            "tags",
            "tags_match",
            "tag_groups",
            "types",
            "verification_mode"
          ])
          |> Map.put("budget", normalize_budget(Map.get(payload, "budget", "mid")))
          |> Map.put_new("max_tokens", Map.get(payload, "max_tokens", 4096))
          |> then(&{:ok, &1})
        end

      key ->
        {:error,
         Error.new(:invalid_request, %{
           message: "#{key} is not part of hindsight's recall contract"
         })}
    end
  end

  defp normalize_budget(budget) when budget in [:low, :mid, :high], do: Atom.to_string(budget)
  defp normalize_budget(budget) when budget in ["low", "mid", "high"], do: budget
  defp normalize_budget(_budget), do: "mid"

  defp source_expansion_mode?(%{"verification_mode" => "source_expansion"}), do: true
  defp source_expansion_mode?(_params), do: false

  defp memory_breadth_mode?(%{"verification_mode" => "memory_breadth"}), do: true
  defp memory_breadth_mode?(_params), do: false

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
    case parse_datetime(value) do
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

  defp memory_score(memory_unit) do
    tags_bonus = min(length(memory_unit.tags || []), 5) * 0.01
    observation_bonus = if memory_unit.fact_type == :observation, do: 0.02, else: 0.0
    min(1.0, 0.9 + tags_bonus + observation_bonus)
  end

  defp entity_total(repo, bank_id, repo_opts) do
    repo.aggregate(from(entity in Entity, where: entity.bank_id == ^bank_id), :count, repo_opts)
  end

  defp load_entity_names_by_unit(_repo, [], _repo_opts), do: %{}

  defp load_entity_names_by_unit(repo, unit_ids, repo_opts) do
    from(link in MemoryUnitEntity,
      join: entity in Entity,
      on: entity.id == link.entity_id,
      where: link.memory_unit_id in ^unit_ids,
      select: {link.memory_unit_id, entity.canonical_name}
    )
    |> repo.all(repo_opts)
    |> Enum.group_by(fn {unit_id, _name} -> unit_id end, fn {_unit_id, name} -> name end)
  end

  defp build_entity_states(repo, bank_id, results, repo_opts) do
    names =
      results
      |> Enum.flat_map(&Map.get(&1, "entities", []))
      |> Enum.uniq()

    entities =
      from(entity in Entity,
        where: entity.bank_id == ^bank_id and entity.canonical_name in ^names
      )
      |> repo.all(repo_opts)
      |> Map.new(&{&1.canonical_name, &1})

    Map.new(names, fn name ->
      entity = Map.get(entities, name)

      observations =
        results
        |> Enum.filter(&(name in Map.get(&1, "entities", [])))
        |> Enum.map(fn result ->
          %{"text" => result["text"], "mentioned_at" => result["mentioned_at"]}
        end)

      {name,
       %{
         "entity_id" => entity && entity.id,
         "canonical_name" => name,
         "observations" => observations
       }}
    end)
  end

  defp build_chunks(results) do
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

  defp build_source_facts(repo, results, _entity_names_by_unit, repo_opts) do
    source_ids =
      results
      |> Enum.flat_map(&Map.get(&1, "source_fact_ids", []))
      |> Enum.uniq()

    source_units =
      from(unit in MemoryUnit, where: unit.id in ^source_ids)
      |> repo.all(repo_opts)

    source_entity_names =
      load_entity_names_by_unit(repo, Enum.map(source_units, & &1.id), repo_opts)

    Map.new(source_units, fn unit ->
      source_item = memory_unit_to_recall_response(unit, memory_unit_vector_list(unit) || [])

      {to_string(unit.id),
       recall_result_from_item(source_item, Map.get(source_entity_names, unit.id, []), false)}
    end)
  end

  defp document_attrs(bank_id, item) do
    case document_ref(item) do
      nil ->
        nil

      external_id ->
        %{
          bank_id: bank_id,
          external_id: external_id,
          title: item["document_title"] || get_in(item, ["metadata", "document_title"]),
          original_text: item["document_text"] || get_in(item, ["metadata", "document_text"]),
          content_hash: item["content_hash"] || get_in(item, ["metadata", "content_hash"]),
          file_storage_key:
            item["file_storage_key"] || get_in(item, ["metadata", "file_storage_key"]),
          file_original_name:
            item["file_original_name"] || get_in(item, ["metadata", "file_original_name"]),
          file_content_type:
            item["file_content_type"] || get_in(item, ["metadata", "file_content_type"]),
          tags:
            List.wrap(
              item["document_tags"] ||
                get_in(item, ["metadata", "document_tags"]) ||
                item["tags"] ||
                []
            ),
          metadata: document_metadata(item)
        }
    end
  end

  defp document_metadata(item) do
    item
    |> Map.get("metadata", %{})
    |> Map.drop(["document_id", "document_title", "document_tags"])
  end

  defp document_ref(item) do
    item["document_id"] || item["document_ref"] || get_in(item, ["metadata", "document_id"])
  end

  # Provenance for this memory within its source document (page / section / element
  # / char span), supplied by structure-preserving ingestion. Only accept a map;
  # plain-text retains carry none.
  defp retain_source_location(%{"source_location" => location})
       when is_map(location) and
              map_size(location) > 0,
       do: location

  defp retain_source_location(_item), do: nil

  defp maybe_filter_document_query(query, nil), do: query
  defp maybe_filter_document_query(query, ""), do: query

  defp maybe_filter_document_query(query, value) do
    pattern = "%#{value}%"

    from(document in query,
      where:
        ilike(document.external_id, ^pattern) or ilike(coalesce(document.title, ""), ^pattern)
    )
  end

  defp maybe_filter_document_tags(query, nil), do: query
  defp maybe_filter_document_tags(query, []), do: query

  defp maybe_filter_document_tags(query, tags) do
    from(document in query,
      where: fragment("? && CAST(? AS text[])", document.tags, ^tags)
    )
  end

  defp maybe_filter_scope_keys(items, nil), do: items
  defp maybe_filter_scope_keys(items, []), do: items

  defp maybe_filter_scope_keys(items, scope_keys) when is_list(scope_keys) do
    Enum.filter(items, fn item ->
      ConsolidationPersistence.scope_key_for_item(item) in scope_keys
    end)
  end

  defp document_to_response(document, counts_by_document) do
    %{
      "id" => document.external_id,
      "bank_id" => document.bank_id,
      "content_hash" => document.content_hash,
      "created_at" => format_datetime(document.inserted_at),
      "updated_at" => format_datetime(document.updated_at),
      "text_length" => document.original_text && String.length(document.original_text),
      "memory_unit_count" => Map.get(counts_by_document, document.external_id, 0),
      "tags" => document.tags,
      "metadata" => document.metadata
    }
  end

  defp maybe_enqueue_auto_consolidation(ctx, items, opts, repo_opts) do
    repo = Keyword.fetch!(opts, :repo)
    queue = Keyword.fetch!(opts, :queue)

    ConsolidationSupport.maybe_enqueue_auto_consolidation(
      ctx,
      items,
      repo,
      queue,
      opts,
      &ConsolidationPersistence.scope_key_for_item/1,
      repo_opts
    )
  end

  defp fetch_bank(repo, bank_id, repo_opts) do
    case repo.get(Bank, bank_id, repo_opts) do
      nil -> {:error, Error.new(:not_found, %{message: "bank not found"})}
      bank -> {:ok, bank}
    end
  end

  defp consolidation_groups(repo, bank_id, payload, repo_opts) do
    ConsolidationPersistence.consolidation_groups(repo, bank_id, payload, repo_opts)
  end

  defp pool_observations(repo, bank_id, scope_key, repo_opts) do
    ConsolidationPersistence.pool_observations(repo, bank_id, scope_key, repo_opts)
  end

  defp resolve_consolidation_source_facts(repo, bank_id, source_ids, repo_opts) do
    ConsolidationPersistence.resolve_source_facts(repo, bank_id, source_ids, repo_opts)
  end

  defp stamp_consolidation_failed!(repo, unit_ids, repo_opts) do
    ConsolidationPersistence.stamp_consolidation_failed!(repo, unit_ids, repo_opts)
  end

  defp apply_prepared!(repo, bank, prepared, repo_opts) do
    ConsolidationPersistence.apply_prepared!(repo, bank, prepared, repo_opts)
  end

  defp refresh_mental_model!(repo, bank, scope_key, scope_observations, units, repo_opts) do
    ConsolidationPersistence.refresh_mental_model!(
      repo,
      bank,
      scope_key,
      scope_observations,
      units,
      repo_opts,
      &bank_document_record/4
    )
  end

  defp active_mental_models(repo, ctx, bank_id, payload, repo_opts, opts) do
    with_tenant_scope(ctx, repo, opts, fn ->
      active_mental_model_documents(repo, bank_id, payload, repo_opts)
    end)
  rescue
    _ -> []
  end

  # Unscoped body of active_mental_models/6, for callers already inside the tenant scope.
  defp active_mental_model_documents(repo, bank_id, payload, repo_opts) do
    tags = List.wrap(payload["tags"])

    excluded_ids =
      Map.get(payload, "exclude_mental_model_ids", []) |> List.wrap() |> MapSet.new()

    from(document in Document,
      where: document.bank_id == ^bank_id,
      where: fragment("?->>'document_type' = 'mental_model'", document.metadata),
      order_by: [asc: document.external_id]
    )
    |> repo.all(repo_opts)
    |> Enum.filter(fn document ->
      not MapSet.member?(excluded_ids, document.external_id) and
        (tags == [] or document.tags == [] or Enum.any?(document.tags, &(&1 in tags)))
    end)
  end

  defp create_mental_model_placeholder(repo, queue, ctx, bank_id, attrs, opts, repo_opts) do
    document_attrs = mental_model_document_attrs(%Document{}, bank_id, attrs)

    %Document{}
    |> Document.changeset(document_attrs)
    |> repo.insert(repo_opts)
    |> case do
      {:ok, document} ->
        enqueue_payload = %{"bank_id" => bank_id, "mental_model_id" => document.external_id}

        case queue.enqueue_refresh_mental_model(ctx, enqueue_payload, opts) do
          {:ok, result} ->
            {:ok,
             %{
               "mental_model_id" => document.external_id,
               "operation_id" => result["operation_id"]
             }}

          {:error, %Error{} = error} ->
            _ = repo.delete(document, repo_opts)
            {:error, error}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, Error.new(:invalid_request, %{message: format_changeset(changeset)})}
    end
  end

  defp generated_mental_model_id do
    "mm-" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  defp mental_model_to_based_on(document) do
    %{
      "id" => document.external_id,
      "title" => document.title,
      "text" => document.original_text,
      "tags" => document.tags
    }
  end

  defp normalize_entity_name(name) do
    name
    |> String.downcase()
    |> String.trim()
  end

  defp active_directives(repo, ctx, bank_id, payload, repo_opts, opts) do
    with_tenant_scope(ctx, repo, opts, fn ->
      from(directive in Directive,
        where: directive.bank_id == ^bank_id and directive.is_active == true,
        order_by: [desc: directive.priority, asc: directive.inserted_at]
      )
      |> repo.all(repo_opts)
      |> Enum.filter(&directive_matches_tags?(&1, payload))
    end)
  rescue
    _ -> []
  end

  defp directive_matches_tags?(directive, %{"tags" => tags}) when is_list(tags) and tags != [] do
    directive.tags == [] or Enum.any?(directive.tags, &(&1 in tags))
  end

  defp directive_matches_tags?(_directive, _payload), do: true

  defp based_on_memory(result) do
    %{
      "id" => result["id"],
      "text" => result["text"],
      "mentioned_at" => result["mentioned_at"],
      "type" => result["type"],
      # Provenance: which source document this memory came from, and where within
      # it — so an answer can be traced back to (document, location) → original file.
      "document_ref" => result["document_id"] || result["document_ref"],
      "source_location" => result["source_location"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp directive_to_based_on(directive) do
    %{
      "id" => directive.id,
      "name" => directive.name,
      "content" => directive.content,
      "priority" => directive.priority,
      "tags" => directive.tags
    }
  end

  defp put_strategy_score(item, strategy_key, score) do
    Map.put(item, strategy_key, score)
  end

  defp keyword_score(memory_unit, query) do
    haystack = "#{memory_unit.content} #{memory_unit.context}" |> String.downcase()

    query
    |> keyword_terms()
    |> then(fn tokens ->
      case tokens do
        [] -> 0.0
        _ -> Enum.count(tokens, &String.contains?(haystack, &1)) / length(tokens)
      end
    end)
    |> Float.round(6)
  end

  # Batched read of the stored memory_links graph: for each candidate,
  # the strongest edge weight of the given link_type connecting it to any seed
  # (either direction, since edges are directed). One query for the whole set.
  defp stored_link_scores(_repo, _bank_id, _link_type, [], _candidate_ids, _repo_opts), do: %{}
  defp stored_link_scores(_repo, _bank_id, _link_type, _seed_ids, [], _repo_opts), do: %{}

  defp stored_link_scores(repo, bank_id, link_type, seed_ids, candidate_ids, repo_opts) do
    seed_set = MapSet.new(seed_ids)

    from(link in MemoryLink,
      where:
        link.bank_id == ^bank_id and link.link_type == ^link_type and
          ((link.from_unit_id in ^seed_ids and link.to_unit_id in ^candidate_ids) or
             (link.from_unit_id in ^candidate_ids and link.to_unit_id in ^seed_ids)),
      select: {link.from_unit_id, link.to_unit_id, link.weight}
    )
    |> repo.all(repo_opts)
    |> Enum.reduce(%{}, fn {from_id, to_id, weight}, acc ->
      candidate_id = if MapSet.member?(seed_set, from_id), do: to_id, else: from_id
      Map.update(acc, candidate_id, weight, &max(&1, weight))
    end)
  end

  defp graph_score(
         memory_unit,
         normalized_query_entities,
         seed_ids,
         query_embedding,
         hop,
         seed_overlap,
         source_seed?,
         source_overlap_count,
         source_shortfall_bonus,
         stored_link_score
       ) do
    memory_entities =
      memory_unit.content
      |> Foresight.EntityExtractors.Simple.extract()
      |> Enum.map(&normalize_entity_name/1)
      |> Enum.uniq()

    shared_entity_count = Enum.count(normalized_query_entities, &(&1 in memory_entities))
    entity_score = :math.tanh(shared_entity_count * 0.5)

    semantic_score =
      memory_unit_similarity(memory_unit, query_embedding)
      |> then(fn similarity ->
        if similarity >= @graph_semantic_floor, do: similarity, else: 0.0
      end)

    causal_score =
      if Enum.any?(memory_unit.source_memory_ids || [], &(&1 in seed_ids)), do: 1.0, else: 0.0

    source_seed_score = if source_seed?, do: 1.0, else: 0.0
    source_link_score = min(source_overlap_count, 3) * 0.35
    overlap_bonus = min(length(seed_overlap), 3) * 0.1
    # Stored semantic-link convergence: the precomputed kNN edge weight
    # (∈[0.7,1.0]) between this candidate and the seed set. Independent of the
    # direct query->unit similarity already captured in semantic_score.
    stored_link_term = stored_link_score * 1.0
    hop_decay = :math.pow(@graph_decay, hop)

    Float.round(
      (entity_score + semantic_score + causal_score + source_seed_score + source_link_score +
         overlap_bonus + source_shortfall_bonus + stored_link_term) * hop_decay,
      6
    )
  end

  defp source_expansion_traversal_score(
         memory_unit,
         query_embedding,
         hop,
         frontier_overlap_count,
         source_seed_overlap_count,
         source_expansion_context,
         source_shortfall_type
       ) do
    semantic_score =
      memory_unit_similarity(memory_unit, query_embedding)
      |> max(0.0)

    frontier_score = min(frontier_overlap_count, 3) * 0.5
    source_seed_score = min(source_seed_overlap_count, 3) * 0.75

    shortfall_bonus =
      source_expansion_shortfall_bonus(
        memory_unit,
        source_expansion_context,
        source_shortfall_type
      )

    hop_decay = :math.pow(@graph_decay, hop)

    Float.round(
      (semantic_score + frontier_score + source_seed_score + shortfall_bonus) * hop_decay,
      6
    )
  end

  defp source_expansion_context(direct_units, source_seed_ids) do
    seed_document_families =
      direct_units
      |> Enum.filter(&MapSet.member?(source_seed_ids, &1.id))
      |> Enum.map(&source_expansion_document_family/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    seed_memory_families =
      direct_units
      |> Enum.filter(&MapSet.member?(source_seed_ids, &1.id))
      |> Enum.map(&source_expansion_memory_family/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{
      source_seed_ids: source_seed_ids,
      seed_document_families: seed_document_families,
      seed_memory_families: seed_memory_families
    }
  end

  defp source_expansion_shortfall_type(%{"source_shortfall_type" => type})
       when type in ["source_family", "source_lineage", "source_provenance", "raw_memory_breadth"] do
    type
  end

  defp source_expansion_shortfall_type(_params), do: nil

  defp source_expansion_novel_only?(%{
         "verification_mode" => "source_expansion",
         "source_shortfall_type" => "source_provenance",
         "source_novel_only" => true
       }),
       do: true

  defp source_expansion_novel_only?(_params), do: false

  defp source_expansion_shortfall_bonus(_memory_unit, _context, nil), do: 0.0

  defp source_expansion_shortfall_bonus(memory_unit, context, "source_family") do
    family_bonus =
      case source_expansion_document_family(memory_unit) do
        nil ->
          0.0

        family ->
          if MapSet.member?(context.seed_document_families, family), do: 0.0, else: 0.9
      end

    Float.round(family_bonus, 6)
  end

  defp source_expansion_shortfall_bonus(memory_unit, context, "raw_memory_breadth") do
    family_bonus =
      case source_expansion_memory_family(memory_unit) do
        nil ->
          0.0

        family ->
          if MapSet.member?(context.seed_memory_families, family), do: 0.0, else: 1.1
      end

    source_bonus =
      memory_unit.source_memory_ids
      |> List.wrap()
      |> length()
      |> min(3)
      |> Kernel.*(0.1)

    Float.round(family_bonus + source_bonus, 6)
  end

  defp source_expansion_shortfall_bonus(memory_unit, context, "source_lineage") do
    source_ids = memory_unit.source_memory_ids |> List.wrap() |> MapSet.new()

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

  defp source_expansion_shortfall_bonus(memory_unit, context, "source_provenance") do
    novel_source_count =
      memory_unit.source_memory_ids
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.difference(context.source_seed_ids)
      |> MapSet.size()

    Float.round(min(novel_source_count, 3) * 0.75, 6)
  end

  defp source_expansion_document_family(%{document_ref: document_ref})
       when is_binary(document_ref) and document_ref != "" do
    "document_family:#{document_ref}"
  end

  defp source_expansion_document_family(_memory_unit), do: nil

  defp source_expansion_memory_family(%{document_ref: document_ref})
       when is_binary(document_ref) and document_ref != "" do
    "memory_family:document:#{document_ref}"
  end

  defp source_expansion_memory_family(%{id: id}) when is_binary(id) and id != "" do
    "memory_family:memory:#{id}"
  end

  defp source_expansion_memory_family(_memory_unit), do: nil

  defp source_expansion_frontier_evidence(_memory_unit, _context, nil), do: %{}

  defp source_expansion_frontier_evidence(memory_unit, context, "source_family") do
    group = source_expansion_document_family(memory_unit)
    novel? = is_binary(group) and not MapSet.member?(context.seed_document_families, group)

    %{
      "group" => group,
      "novel_count" => if(novel?, do: 1, else: 0),
      "priority" => if(novel?, do: "novel_document_family", else: "existing_document_family")
    }
  end

  defp source_expansion_frontier_evidence(memory_unit, context, "raw_memory_breadth") do
    group = source_expansion_memory_family(memory_unit)
    novel? = is_binary(group) and not MapSet.member?(context.seed_memory_families, group)

    %{
      "group" => group,
      "novel_count" => if(novel?, do: 1, else: 0),
      "priority" => if(novel?, do: "novel_memory_family", else: "existing_memory_family")
    }
  end

  defp source_expansion_frontier_evidence(memory_unit, context, "source_lineage") do
    source_ids = memory_unit.source_memory_ids |> List.wrap() |> Enum.map(&to_string/1)
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

  defp source_expansion_frontier_evidence(memory_unit, context, "source_provenance") do
    source_ids = memory_unit.source_memory_ids |> List.wrap() |> Enum.map(&to_string/1)
    novel_source_ids = Enum.reject(source_ids, &MapSet.member?(context.source_seed_ids, &1))

    %{
      "group" => "source_cluster:#{Enum.sort(source_ids) |> Enum.join("|")}",
      "novel_count" => length(novel_source_ids),
      "priority" =>
        if(novel_source_ids != [], do: "novel_source_cluster", else: "existing_source_cluster")
    }
  end

  defp source_expansion_frontier_evidence(_memory_unit, _context, _source_shortfall_type), do: %{}

  defp source_expansion_seed_fetch_limit(params, nil), do: recall_budget(params)

  defp source_expansion_seed_fetch_limit(params, _source_shortfall_type) do
    min(recall_budget(params) * 3, max(recall_budget(params), 1) * 3)
  end

  defp source_expansion_seed_limit(params, nil), do: recall_budget(params)
  defp source_expansion_seed_limit(%{"budget" => "low"}, _source_shortfall_type), do: 1
  defp source_expansion_seed_limit(%{"budget" => "mid"}, _source_shortfall_type), do: 2
  defp source_expansion_seed_limit(%{"budget" => "high"}, _source_shortfall_type), do: 2
  defp source_expansion_seed_limit(_params, _source_shortfall_type), do: 2

  defp prioritize_source_expansion_seeds(units, _query_embedding, nil), do: units

  defp prioritize_source_expansion_seeds(units, query_embedding, source_shortfall_type) do
    units
    |> Enum.sort_by(fn unit ->
      semantic_score =
        memory_unit_similarity(unit, query_embedding)
        |> max(0.0)

      {-source_expansion_seed_priority(unit, source_shortfall_type), -semantic_score, unit.id}
    end)
  end

  defp source_expansion_seed_priority(memory_unit, "source_family") do
    document_bonus =
      if is_binary(memory_unit.document_ref) and memory_unit.document_ref != "",
        do: 2.0,
        else: 0.0

    source_breadth_bonus = min(length(memory_unit.source_memory_ids || []), 3) * 0.15

    Float.round(document_bonus + source_breadth_bonus, 6)
  end

  defp source_expansion_seed_priority(memory_unit, "raw_memory_breadth") do
    family_bonus =
      if is_binary(source_expansion_memory_family(memory_unit)),
        do: 2.2,
        else: 0.0

    source_breadth_bonus = min(length(memory_unit.source_memory_ids || []), 3) * 0.25

    Float.round(family_bonus + source_breadth_bonus, 6)
  end

  defp source_expansion_seed_priority(memory_unit, "source_lineage") do
    source_ids = memory_unit.source_memory_ids || []
    multi_source_bonus = if length(source_ids) > 1, do: 2.0, else: 0.0
    source_breadth_bonus = min(length(source_ids), 3) * 0.35

    Float.round(multi_source_bonus + source_breadth_bonus, 6)
  end

  defp source_expansion_seed_priority(memory_unit, "source_provenance") do
    source_ids = memory_unit.source_memory_ids || []
    Float.round(min(length(source_ids), 3) * 0.85, 6)
  end

  defp source_expansion_seed_priority(_memory_unit, _source_shortfall_type), do: 0.0

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
       -item.frontier_overlap_count, item.unit.id}
    end)
  end

  defp prioritize_source_expansion_frontier(items, _context, "source_family") do
    items
    |> Enum.sort_by(fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit.id}
    end)
    |> take_distinct_frontier_groups(&source_expansion_document_family(&1.unit))
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        {-item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit.id}
      end)
    )
    |> Enum.uniq_by(& &1.unit.id)
  end

  defp prioritize_source_expansion_frontier(items, _context, "raw_memory_breadth") do
    items
    |> Enum.sort_by(fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit.id}
    end)
    |> take_distinct_frontier_groups(&source_expansion_memory_family(&1.unit))
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        {-item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit.id}
      end)
    )
    |> Enum.uniq_by(& &1.unit.id)
  end

  defp prioritize_source_expansion_frontier(items, context, "source_lineage") do
    items
    |> Enum.sort_by(fn item ->
      novel_lineage_sources =
        item.unit.source_memory_ids
        |> List.wrap()
        |> MapSet.new()
        |> MapSet.difference(context.source_seed_ids)
        |> MapSet.size()

      {-novel_lineage_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit.id}
    end)
    |> take_distinct_frontier_groups(fn item ->
      get_in(item.frontier_evidence, ["group"])
    end)
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        novel_lineage_sources =
          item.unit.source_memory_ids
          |> List.wrap()
          |> MapSet.new()
          |> MapSet.difference(context.source_seed_ids)
          |> MapSet.size()

        {-novel_lineage_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit.id}
      end)
    )
    |> Enum.uniq_by(& &1.unit.id)
  end

  defp prioritize_source_expansion_frontier(items, context, "source_provenance") do
    items
    |> Enum.sort_by(fn item ->
      novel_sources =
        item.unit.source_memory_ids
        |> List.wrap()
        |> MapSet.new()
        |> MapSet.difference(context.source_seed_ids)
        |> MapSet.size()

      {-novel_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit.id}
    end)
    |> take_distinct_frontier_groups(fn item ->
      get_in(item.frontier_evidence, ["group"])
    end)
    |> Kernel.++(
      items
      |> Enum.sort_by(fn item ->
        novel_sources =
          item.unit.source_memory_ids
          |> List.wrap()
          |> MapSet.new()
          |> MapSet.difference(context.source_seed_ids)
          |> MapSet.size()

        {-novel_sources, -item.source_traversal_score, -item.source_seed_overlap_count,
         -item.frontier_overlap_count, item.unit.id}
      end)
    )
    |> Enum.uniq_by(& &1.unit.id)
  end

  defp prioritize_source_expansion_frontier(items, _context, _source_shortfall_type) do
    Enum.sort_by(items, fn item ->
      {-item.source_traversal_score, -item.source_seed_overlap_count,
       -item.frontier_overlap_count, item.unit.id}
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

  defp temporal_runtime_score(memory_unit, item, temporal_constraint, query_timestamp) do
    base_score = temporal_score(memory_unit, temporal_constraint, query_timestamp)

    source_overlap = item["temporal_source_overlap"] || []
    seed_score = Map.get(item, "temporal_seed_score", 0.0)
    overlap_bonus = Map.get(item, "temporal_overlap_bonus", 0.0)
    hop = Map.get(item, "temporal_hop", 0)
    hop_decay = :math.pow(@temporal_decay, max(hop - 1, 0))

    link_boost =
      cond do
        source_overlap != [] -> @temporal_link_boost
        true -> @temporal_entry_boost
      end

    # Stored temporal-link convergence: additive edge weight (∈[0.3,1.0])
    # to the temporal entry seeds from the retain-time proximity graph.
    stored_link_score = Map.get(item, "temporal_stored_link_score", 0.0)

    Float.round(
      base_score * link_boost * hop_decay + seed_score + overlap_bonus + stored_link_score,
      6
    )
  end

  defp temporal_score(memory_unit, temporal_constraint, query_timestamp) do
    unit_datetime =
      memory_unit.occurred_end || memory_unit.occurred_start || memory_unit.occurred_at ||
        memory_unit.mentioned_at

    anchor =
      case temporal_constraint do
        %{from: from_dt, to: to_dt} ->
          DateTime.add(from_dt, div(DateTime.diff(to_dt, from_dt), 2), :second)
      end

    cond do
      is_nil(unit_datetime) or is_nil(anchor) ->
        0.0

      true ->
        delta_days = abs(DateTime.diff(unit_datetime, anchor, :day))
        base = if delta_days == 0, do: 1.0, else: 1.0 / (delta_days + 1)
        if query_timestamp, do: Float.round(base, 6), else: Float.round(base * 0.9, 6)
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

  defp recall_score(memory_unit, query_embedding) do
    vector_score =
      memory_unit_similarity(memory_unit, query_embedding)

    type_bonus = if memory_unit.fact_type == :observation, do: 0.02, else: 0.0
    recency_bonus = if fresh?(memory_unit.mentioned_at), do: 0.01, else: 0.0

    (vector_score + type_bonus + recency_bonus)
    |> min(1.0)
    |> Float.round(6)
  end

  defp cosine_similarity(left, right) when is_list(left) and is_list(right) do
    {dot, left_norm, right_norm} =
      Enum.zip(left, right)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {l, r}, {dot, left_norm, right_norm} ->
        {dot + l * r, left_norm + l * l, right_norm + r * r}
      end)

    denom = :math.sqrt(left_norm) * :math.sqrt(right_norm)

    if denom == 0.0 do
      0.0
    else
      max(0.0, min(1.0, dot / denom))
    end
  end

  defp fresh?(nil), do: false

  defp fresh?(%DateTime{} = mentioned_at) do
    DateTime.diff(DateTime.utc_now(), mentioned_at, :day) <= 30
  end

  defp recall_budget(params) do
    budget = Map.get(params, "budget", "mid")

    case Map.get(params, "recall_budget_function", "fixed") do
      "adaptive" -> adaptive_recall_budget(params, budget)
      _ -> fixed_recall_budget(params, budget)
    end
  end

  # Rerank shortlist size = 2× the resolved recall budget (Hindsight parity); logic +
  # rationale live in Foresight.Recall.RerankWindow (independently unit-tested).
  # recall_budget/1 already mirrors Hindsight's _resolve_thinking_budget.
  defp recall_rerank_window(params) do
    Foresight.Recall.RerankWindow.size(params, recall_budget(params))
  end

  defp fixed_recall_budget(params, "low"),
    do: recall_integer(Map.get(params, "recall_budget_fixed_low"), 100)

  defp fixed_recall_budget(params, "high"),
    do: recall_integer(Map.get(params, "recall_budget_fixed_high"), 1000)

  defp fixed_recall_budget(params, _budget),
    do: recall_integer(Map.get(params, "recall_budget_fixed_mid"), 300)

  defp adaptive_recall_budget(params, budget) do
    max_tokens = max(recall_integer(Map.get(params, "max_tokens"), 0), 1)
    minimum = max(recall_integer(Map.get(params, "recall_budget_min"), 20), 1)
    maximum = max(recall_integer(Map.get(params, "recall_budget_max"), 2000), minimum)

    ratio =
      case budget do
        "low" -> recall_number(Map.get(params, "recall_budget_adaptive_low"), 0.025)
        "high" -> recall_number(Map.get(params, "recall_budget_adaptive_high"), 0.25)
        _ -> recall_number(Map.get(params, "recall_budget_adaptive_mid"), 0.075)
      end

    max_tokens
    |> Kernel.*(ratio)
    |> round()
    |> max(minimum)
    |> min(maximum)
  end

  defp recall_integer(value, _default) when is_integer(value), do: value
  defp recall_integer(_value, default), do: default

  defp recall_number(value, _default) when is_float(value), do: value
  defp recall_number(value, _default) when is_integer(value), do: value / 1
  defp recall_number(_value, default), do: default

  defp semantic_candidate_limit(params), do: recall_budget(params)

  defp semantic_fetch_limit(params) do
    max(
      semantic_candidate_limit(params) * @semantic_overfetch_multiplier,
      @semantic_overfetch_min
    )
  end

  defp temporal_entry_point_limit(params),
    do: min(@temporal_entry_point_limit, recall_budget(params))

  defp temporal_result_limit(params), do: min(@temporal_result_limit, recall_budget(params))

  defp first_type([type | _rest]), do: type
  defp first_type(_types), do: nil

  # A negative limit or offset is not a page; clamp rather than hand Postgres a
  # negative LIMIT/OFFSET (an error) or Enum.take a tail (a surprise).
  defp normalize_limit(%{"limit" => limit}) when is_integer(limit), do: max(limit, 0)
  defp normalize_limit(_params), do: @default_limit

  defp normalize_min_count(%{"min_count" => min_count}) when is_integer(min_count), do: min_count
  defp normalize_min_count(_params), do: 1

  defp normalize_offset(%{"offset" => offset}) when is_integer(offset), do: max(offset, 0)
  defp normalize_offset(_params), do: @default_offset

  defp audit_log_period_start("1d"), do: DateTime.add(now(), -1 * 24 * 60 * 60, :second)
  defp audit_log_period_start("30d"), do: DateTime.add(now(), -30 * 24 * 60 * 60, :second)
  defp audit_log_period_start(_period), do: DateTime.add(now(), -7 * 24 * 60 * 60, :second)

  defp merge_bank_background(current_mission, content) do
    current = String.trim(current_mission || "")
    incoming = String.trim(content || "")

    cond do
      current == "" -> incoming
      incoming == "" -> current
      String.contains?(current, incoming) -> current
      true -> "#{current} #{incoming}"
    end
  end

  defp memories_timeseries_query(bank_id, "mentioned_at", config, window_start) do
    from(unit in MemoryUnit,
      where:
        unit.bank_id == ^bank_id and
          fragment("COALESCE(?, ?) >= ?", unit.mentioned_at, unit.inserted_at, ^window_start),
      group_by: [
        fragment(
          "date_trunc(?, COALESCE(?, ?) AT TIME ZONE 'UTC')",
          ^config.trunc,
          unit.mentioned_at,
          unit.inserted_at
        ),
        unit.fact_type
      ],
      order_by: [
        asc:
          fragment(
            "date_trunc(?, COALESCE(?, ?) AT TIME ZONE 'UTC')",
            ^config.trunc,
            unit.mentioned_at,
            unit.inserted_at
          )
      ],
      select: %{
        bucket:
          type(
            fragment(
              "date_trunc(?, COALESCE(?, ?) AT TIME ZONE 'UTC')",
              ^config.trunc,
              unit.mentioned_at,
              unit.inserted_at
            ),
            :utc_datetime_usec
          ),
        fact_type: unit.fact_type,
        count: count(unit.id)
      }
    )
  end

  defp memories_timeseries_query(bank_id, "occurred_start", config, window_start) do
    from(unit in MemoryUnit,
      where:
        unit.bank_id == ^bank_id and
          fragment(
            "COALESCE(?, ?) >= ?",
            unit.occurred_start,
            unit.inserted_at,
            ^window_start
          ),
      group_by: [
        fragment(
          "date_trunc(?, COALESCE(?, ?) AT TIME ZONE 'UTC')",
          ^config.trunc,
          unit.occurred_start,
          unit.inserted_at
        ),
        unit.fact_type
      ],
      order_by: [
        asc:
          fragment(
            "date_trunc(?, COALESCE(?, ?) AT TIME ZONE 'UTC')",
            ^config.trunc,
            unit.occurred_start,
            unit.inserted_at
          )
      ],
      select: %{
        bucket:
          type(
            fragment(
              "date_trunc(?, COALESCE(?, ?) AT TIME ZONE 'UTC')",
              ^config.trunc,
              unit.occurred_start,
              unit.inserted_at
            ),
            :utc_datetime_usec
          ),
        fact_type: unit.fact_type,
        count: count(unit.id)
      }
    )
  end

  defp memories_timeseries_query(bank_id, _time_field, config, window_start) do
    from(unit in MemoryUnit,
      where: unit.bank_id == ^bank_id and unit.inserted_at >= ^window_start,
      group_by: [
        fragment("date_trunc(?, ? AT TIME ZONE 'UTC')", ^config.trunc, unit.inserted_at),
        unit.fact_type
      ],
      order_by: [
        asc: fragment("date_trunc(?, ? AT TIME ZONE 'UTC')", ^config.trunc, unit.inserted_at)
      ],
      select: %{
        bucket:
          type(
            fragment("date_trunc(?, ? AT TIME ZONE 'UTC')", ^config.trunc, unit.inserted_at),
            :utc_datetime_usec
          ),
        fact_type: unit.fact_type,
        count: count(unit.id)
      }
    )
  end

  defp memories_timeseries_config("1h"),
    do: %{period: "1h", trunc: "minute", count: 60, step_seconds: 60, interval_seconds: 3600}

  defp memories_timeseries_config("12h"),
    do: %{
      period: "12h",
      trunc: "hour",
      count: 12,
      step_seconds: 3600,
      interval_seconds: 12 * 3600
    }

  defp memories_timeseries_config("1d"),
    do: %{
      period: "1d",
      trunc: "hour",
      count: 24,
      step_seconds: 3600,
      interval_seconds: 24 * 3600
    }

  defp memories_timeseries_config("30d"),
    do: %{
      period: "30d",
      trunc: "day",
      count: 30,
      step_seconds: 86_400,
      interval_seconds: 30 * 86_400
    }

  defp memories_timeseries_config("90d"),
    do: %{
      period: "90d",
      trunc: "day",
      count: 90,
      step_seconds: 86_400,
      interval_seconds: 90 * 86_400
    }

  defp memories_timeseries_config(_period),
    do: %{
      period: "7d",
      trunc: "day",
      count: 7,
      step_seconds: 86_400,
      interval_seconds: 7 * 86_400
    }

  defp normalize_memories_timeseries_time_field(time_field)
       when time_field in ["created_at", "mentioned_at", "occurred_start"],
       do: time_field

  defp normalize_memories_timeseries_time_field(_time_field), do: "created_at"

  defp build_memories_timeseries_buckets(rows, config) do
    end_bucket = memories_timeseries_bucket_anchor(config.trunc)

    buckets =
      for index <- 0..(config.count - 1) do
        bucket_time =
          DateTime.add(end_bucket, -config.step_seconds * (config.count - 1 - index), :second)

        %{
          "time" => format_datetime(bucket_time),
          "world" => 0,
          "experience" => 0,
          "observation" => 0
        }
      end

    bucket_map = Map.new(buckets, fn bucket -> {bucket["time"], bucket} end)

    hydrated =
      Enum.reduce(rows, bucket_map, fn row, acc ->
        time = row.bucket |> normalize_bucket_datetime() |> format_datetime()
        bucket = Map.get(acc, time)

        if is_nil(bucket) do
          acc
        else
          fact_type = row.fact_type |> to_string()
          Map.put(acc, time, Map.update(bucket, fact_type, row.count, &(&1 + row.count)))
        end
      end)

    Enum.map(buckets, fn bucket -> Map.fetch!(hydrated, bucket["time"]) end)
  end

  defp memories_timeseries_bucket_anchor("minute") do
    current = now()
    %{current | second: 0, microsecond: {0, 6}}
  end

  defp memories_timeseries_bucket_anchor("hour") do
    current = now()
    %{current | minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp memories_timeseries_bucket_anchor(_trunc) do
    current = now()
    %{current | hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp normalize_bucket_datetime(%NaiveDateTime{} = bucket) do
    bucket
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp normalize_bucket_datetime(%DateTime{} = bucket) do
    bucket
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
  end

  defp normalize_create_webhook_attrs(bank_id, attrs) do
    with {:ok, url} <- validate_nonempty_string(Map.get(attrs, "url"), "url"),
         {:ok, secret} <- validate_optional_string(Map.get(attrs, "secret"), "secret"),
         {:ok, event_types} <-
           validate_string_list(
             Map.get(attrs, "event_types", ["consolidation.completed"]),
             "event_types"
           ),
         {:ok, enabled} <- validate_boolean(Map.get(attrs, "enabled", true), "enabled"),
         {:ok, http_config} <- normalize_storage_http_config(Map.get(attrs, "http_config", %{})) do
      {:ok,
       %{
         bank_id: bank_id,
         url: url,
         secret: secret,
         event_types: event_types,
         enabled: enabled,
         http_config: http_config
       }}
    end
  end

  defp normalize_patch_webhook_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn
      {"url", value}, {:ok, acc} ->
        case validate_nonempty_string(value, "url") do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, :url, normalized)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {"secret", value}, {:ok, acc} ->
        case validate_optional_string(value, "secret") do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, :secret, normalized)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {"event_types", value}, {:ok, acc} ->
        case validate_string_list(value, "event_types") do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, :event_types, normalized)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {"enabled", value}, {:ok, acc} ->
        case validate_boolean(value, "enabled") do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, :enabled, normalized)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {"http_config", nil}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, :http_config, %{})}}

      {"http_config", value}, {:ok, acc} ->
        case normalize_storage_http_config(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(acc, :http_config, normalized)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {_key, _value}, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  defp normalize_storage_http_config(%{} = http_config) do
    method = Map.get(http_config, "method", Map.get(http_config, :method, "POST"))

    timeout_seconds =
      Map.get(http_config, "timeout_seconds", Map.get(http_config, :timeout_seconds, 30))

    headers = Map.get(http_config, "headers", Map.get(http_config, :headers, %{}))
    params = Map.get(http_config, "params", Map.get(http_config, :params, %{}))

    with {:ok, method} <- validate_http_method(method),
         {:ok, timeout_seconds} <- validate_positive_integer(timeout_seconds, "timeout_seconds"),
         {:ok, headers} <- validate_string_map(headers, "headers"),
         {:ok, params} <- validate_string_map(params, "params") do
      {:ok,
       %{
         "method" => method,
         "timeout_seconds" => timeout_seconds,
         "headers" => headers,
         "params" => params
       }}
    end
  end

  defp normalize_storage_http_config(_value) do
    {:error, Error.new(:invalid_request, %{message: "http_config must be an object"})}
  end

  defp validate_nonempty_string(value, field) when is_binary(value) do
    trimmed = String.trim(value)

    if byte_size(trimmed) > 0 do
      {:ok, trimmed}
    else
      {:error, Error.new(:invalid_request, %{message: "#{field} must be a non-empty string"})}
    end
  end

  defp validate_nonempty_string(_value, field) do
    {:error, Error.new(:invalid_request, %{message: "#{field} must be a non-empty string"})}
  end

  defp validate_optional_string(nil, _field), do: {:ok, nil}
  defp validate_optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp validate_optional_string(_value, field) do
    {:error, Error.new(:invalid_request, %{message: "#{field} must be a string or null"})}
  end

  defp validate_string_list(value, _field) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error, Error.new(:invalid_request, %{message: "event_types must be a list of strings"})}
    end
  end

  defp validate_string_list(_value, field) do
    {:error, Error.new(:invalid_request, %{message: "#{field} must be a list of strings"})}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: {:ok, value}

  defp validate_boolean(_value, field) do
    {:error, Error.new(:invalid_request, %{message: "#{field} must be a boolean"})}
  end

  defp validate_http_method(value) when value in ["GET", "POST"], do: {:ok, value}

  defp validate_http_method(_value) do
    {:error, Error.new(:invalid_request, %{message: "http_config.method must be GET or POST"})}
  end

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate_positive_integer(_value, field) do
    {:error, Error.new(:invalid_request, %{message: "#{field} must be a positive integer"})}
  end

  defp validate_string_map(%{} = value, field) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end) do
      {:ok, value}
    else
      {:error,
       Error.new(:invalid_request, %{message: "#{field} must be an object with string values"})}
    end
  end

  defp validate_string_map(_value, field) do
    {:error,
     Error.new(:invalid_request, %{message: "#{field} must be an object with string values"})}
  end

  defp webhook_response(%Webhook{} = webhook) do
    %{
      "id" => webhook.id,
      "bank_id" => webhook.bank_id,
      "url" => webhook.url,
      "secret" => nil,
      "event_types" => webhook.event_types || [],
      "enabled" => webhook.enabled,
      "http_config" => webhook.http_config || %{},
      "created_at" => format_datetime(webhook.inserted_at),
      "updated_at" => format_datetime(webhook.updated_at)
    }
  end

  defp delivery_response(%Delivery{} = delivery) do
    %{
      "id" => delivery.id,
      "webhook_id" => delivery.webhook_id,
      "url" => delivery.url,
      "event_type" => delivery.event_type,
      "status" => delivery.status,
      "attempts" => delivery.attempts,
      "next_retry_at" => format_datetime(delivery.next_retry_at),
      "last_error" => delivery.last_error,
      "last_response_status" => delivery.last_response_status,
      "last_response_body" => delivery.last_response_body,
      "last_attempt_at" => format_datetime(delivery.last_attempt_at),
      "created_at" => format_datetime(delivery.inserted_at),
      "updated_at" => format_datetime(delivery.updated_at)
    }
  end

  defp maybe_filter_delivery_cursor(query, nil), do: query

  defp maybe_filter_delivery_cursor(query, cursor) when is_binary(cursor) do
    case DateTime.from_iso8601(cursor) do
      {:ok, datetime, _offset} -> where(query, [delivery], delivery.inserted_at < ^datetime)
      _ -> query
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_query_timestamp(nil), do: nil
  defp parse_query_timestamp(value), do: parse_datetime(value)

  # Multilingual temporal extraction. Native period layer always
  # (Foresight.Recall.QueryAnalyzer, port of Hindsight's _extract_period, EN/ES/IT/FR/DE
  # + this-week/this-month/tomorrow extras). The Python `dateparser` single-date tail
  # (200+ languages incl. Greek) runs only when `dateparser: true` — which we pass ONLY
  # on the once-per-recall arm path (ranked_recall_items), never on the per-candidate
  # boost (recall_temporal_factor), so there is at most one worker round-trip per recall.
  defp temporal_constraint(query, query_timestamp),
    do: temporal_constraint(query, query_timestamp, [])

  defp temporal_constraint(query, query_timestamp, opts) when is_binary(query) do
    anchor = parse_query_timestamp(query_timestamp) || DateTime.utc_now()

    analyzer_opts =
      if Keyword.get(opts, :dateparser, false),
        do: [dateparser: &dateparser_date/2],
        else: []

    Foresight.Recall.QueryAnalyzer.analyze(query, anchor, analyzer_opts)
  end

  defp temporal_constraint(_query, _query_timestamp, _opts), do: nil

  # Python-worker-backed single-date extractor for the QueryAnalyzer dateparser seam.
  # Any worker error / unavailability (e.g. cloud deploys with no local ML worker)
  # degrades cleanly to native periods only.
  defp dateparser_date(query, %DateTime{} = reference) do
    case Foresight.ML.PythonLocalWorker.analyze_query(query, DateTime.to_iso8601(reference)) do
      {:ok, iso} when is_binary(iso) ->
        case Date.from_iso8601(iso) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp audit_log_to_response(%AuditLog{} = audit_log) do
    %{
      "id" => audit_log.id,
      "action" => audit_log.action,
      "transport" => audit_log.transport,
      "bank_id" => audit_log.bank_id,
      "started_at" => format_datetime(audit_log.started_at),
      "ended_at" => format_datetime(audit_log.ended_at),
      "duration_ms" => audit_log_duration_ms(audit_log),
      "request" => audit_log.request,
      "response" => audit_log.response,
      "metadata" => audit_log.metadata || %{}
    }
  end

  defp audit_log_duration_ms(%AuditLog{
         started_at: %DateTime{} = started_at,
         ended_at: %DateTime{} = ended_at
       }) do
    DateTime.diff(ended_at, started_at, :millisecond)
  end

  defp audit_log_duration_ms(_audit_log), do: nil

  defp format_changeset(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> inspect()
  end
end
