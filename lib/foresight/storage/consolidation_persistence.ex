defmodule Foresight.Storage.ConsolidationPersistence do
  @moduledoc """
  Consolidation persistence: an Elixir port of Hindsight's
  `engine/consolidation/consolidator.py`. Turns raw `world`/`experience` facts
  into consolidated `observation` memory units via an LLM `creates`/`updates`/
  `deletes` merge contract (`Foresight.Prompts.Consolidation.V1`).

  The LLM call and embedding happen OUTSIDE the DB transaction (see
  `prepare_scope/7`); only the resulting writes run inside it (`apply_prepared!/4`)
  — mirroring the retain path's txn discipline and avoiding the reflect
  txn-across-LLM pool-timeout class of bug.
  """

  import Ecto.Query

  require Logger

  alias DBConnection.ConnectionError
  alias Foresight.Embeddings.Profile, as: EmbeddingProfile
  alias Foresight.Error
  alias Foresight.LLMs.StructuredRecovery
  alias Foresight.Prompts.Consolidation.V1, as: ConsolidationPrompt
  alias Foresight.Schemas.Document
  alias Foresight.Schemas.MemoryLink
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Text.Sanitize

  @mental_model_prefix "mental-model:"
  @default_embedded_dim 384
  @default_batch_size 200

  # ---- pending-fact selection ------------------------------------------------

  @doc """
  Group unconsolidated facts by scope. Only facts with `consolidated_at IS NULL`
  AND `consolidation_failed_at IS NULL` are eligible (mirrors Hindsight's pending
  filter — consolidator.py:290-293,339-341 — so a poison fact quarantined by the
  bisection path is never retried forever; without the failed-at guard the stub
  reprocessed every fact on every run).
  """
  def consolidation_groups(repo, bank_id, payload, repo_opts \\ []) do
    requested_scopes = requested_scope_keys(payload)
    batch_size = batch_size(payload)

    units =
      from(unit in MemoryUnit,
        where:
          unit.bank_id == ^bank_id and unit.fact_type in [:world, :experience] and
            is_nil(unit.consolidated_at) and is_nil(unit.consolidation_failed_at),
        order_by: [asc: unit.mentioned_at, asc: unit.inserted_at],
        limit: ^batch_size
      )
      |> repo.all(repo_opts)
      |> Enum.group_by(&scope_key_for_unit/1)
      |> Enum.reject(fn {_scope, scoped_units} -> scoped_units == [] end)
      |> Enum.filter(fn {scope, _units} ->
        requested_scopes == [] or scope in requested_scopes
      end)

    {:ok, units}
  rescue
    error in ConnectionError ->
      {:error, Error.new(:unavailable, %{message: Exception.message(error)})}
  end

  # ---- existing-observation pooling (read, outside txn) ----------------------

  @doc """
  Pool the existing observations that belong to `scope_key` so the LLM can merge
  against them. Strict scope match (exact tags + observation_scopes) prevents
  cross-scope contamination — the Hindsight `tags_match="all_strict"` guarantee.
  """
  def pool_observations(repo, bank_id, scope_key, repo_opts \\ []) do
    tags = scope_tags(scope_key)

    from(unit in MemoryUnit,
      where:
        unit.bank_id == ^bank_id and unit.fact_type == :observation and unit.tags == ^tags and
          is_nil(unit.superseded_at),
      order_by: [asc: unit.inserted_at]
    )
    |> repo.all(repo_opts)
    |> Enum.filter(&(scope_key_for_unit(&1) == scope_key))
  end

  # ---- phase A: prepare (LLM merge + embed), outside the transaction ---------

  @doc """
  Run the LLM merge for one scope and pre-compute embeddings for every resulting
  create/update. Returns a prepared plan applied later inside the transaction.

  - `{:ok, prepared}` — the LLM call succeeded (even with empty ops); source
    facts for this scope will be stamped `consolidated_at`.
  - `{:skip, reason}` — the LLM/provider was unavailable; the scope is left
    untouched and its facts stay pending (retryable). Degrade-safe: never raises.
  """
  def prepare_scope(
        llm,
        embedder,
        bank,
        scope_key,
        units,
        existing_obs,
        opts,
        source_facts \\ %{}
      ) do
    case llm_merge(llm, bank, scope_key, units, existing_obs, opts, source_facts) do
      {:ok, ops} -> build_prepared(bank, scope_key, units, existing_obs, ops, embedder)
      {:skip, reason} -> {:skip, reason}
    end
  end

  # Embedding + op preparation run here (Phase A, outside the txn). Any raise —
  # an embedder crash, an unknown embedding dimension — degrades this scope to
  # {:skip} rather than poisoning the batch (prepare_scope must never raise).
  defp build_prepared(bank, scope_key, units, existing_obs, ops, embedder) do
    fact_ids = MapSet.new(units, &to_string(&1.id))
    obs_by_id = Map.new(existing_obs, &{to_string(&1.id), &1})

    deletes = prepare_deletes(ops["deletes"], obs_by_id)
    deleted_ids = MapSet.new(deletes, &to_string(&1.id))

    # A DELETE and an UPDATE for the same observation would collide (delete!
    # then a stale update! → Ecto.StaleEntryError, aborting the whole batch).
    # Deletes win; drop any update targeting a deleted observation.
    updates = prepare_updates(ops["updates"], obs_by_id, units, fact_ids, embedder, deleted_ids)
    remaining = create_slots(bank, existing_obs, deletes)
    creates = prepare_creates(ops["creates"], units, fact_ids, embedder, remaining)

    {:ok,
     %{
       scope_key: scope_key,
       units: units,
       source_ids: Enum.map(units, & &1.id),
       # What the merge was built against; apply_chunk re-checks it under the scope
       # lock and skips the plan if a concurrent run changed the pool.
       existing: observation_fingerprint(existing_obs),
       deletes: deletes,
       updates: updates,
       creates: creates
     }}
  rescue
    error -> {:skip, {:preparation_failed, error}}
  end

  # ---- phase B: apply prepared plan, inside the transaction ------------------

  @doc """
  Apply a prepared scope plan (DELETE → UPDATE → CREATE), stamp the scope's
  source facts `consolidated_at`, and return the observations written
  (creates + updates) for downstream mental-model refresh.
  """
  def apply_prepared!(repo, bank, prepared, repo_opts) do
    # A `deletes` entry fires only when an observation is superseded or
    # contradicted by new facts. Instead of destroying it (Hindsight's hard-delete), mark
    # it superseded — excluded from active recall but retained — and record `supersedes`
    # edges from the superseding facts, so history and the conflict are auditable.
    superseded_at = DateTime.truncate(DateTime.utc_now(), :microsecond)

    Enum.each(prepared.deletes, fn observation ->
      supersede_observation!(
        repo,
        bank,
        observation,
        prepared.source_ids,
        superseded_at,
        repo_opts
      )
    end)

    updated =
      Enum.map(prepared.updates, fn update ->
        update.observation
        |> MemoryUnit.changeset(update.attrs)
        |> repo.update!(repo_opts)
      end)

    created =
      Enum.map(prepared.creates, fn create ->
        %MemoryUnit{bank_id: bank.id}
        |> MemoryUnit.changeset(create.attrs)
        |> repo.insert!(repo_opts)
      end)

    stamp_consolidated!(repo, prepared.source_ids, repo_opts)

    updated ++ created
  end

  # Mark `observation` superseded (kept, not deleted) and link each superseding source
  # fact to it with a `supersedes` edge. Edges are de-duplicated on
  # (from_unit_id, to_unit_id, link_type). A source fact never links to itself (facts and
  # observations are distinct units).
  defp supersede_observation!(repo, bank, observation, source_ids, superseded_at, repo_opts) do
    observation
    |> MemoryUnit.changeset(%{superseded_at: superseded_at})
    |> repo.update!(repo_opts)

    Enum.each(source_ids, fn source_id ->
      %MemoryLink{}
      |> MemoryLink.changeset(%{
        bank_id: bank.id,
        from_unit_id: source_id,
        to_unit_id: observation.id,
        link_type: "supersedes",
        weight: 1.0
      })
      |> repo.insert!(
        Keyword.merge(repo_opts,
          on_conflict: :nothing,
          conflict_target: [:from_unit_id, :to_unit_id, :link_type]
        )
      )
    end)
  end

  @doc """
  Serialise every writer of one consolidation scope (sync and Oban runs alike).
  The transaction-scoped advisory lock is released at commit or rollback, so an
  overlapping run waits, then sees committed state. Hindsight holds a per-scope
  lock around the same window (consolidator.py `_resolve_write_scopes`).
  """
  def lock_scope(repo, bank_id, scope_key, repo_opts) do
    repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [bank_id, "consolidate:" <> to_string(scope_key)],
      repo_opts
    )

    :ok
  end

  @doc """
  The subset of `unit_ids` still pending consolidation, locked FOR UPDATE for the
  rest of the transaction. A chunk whose facts a concurrent run already stamped
  must not be applied again.
  """
  def pending_unit_ids(_repo, [], _repo_opts), do: []

  def pending_unit_ids(repo, unit_ids, repo_opts) do
    from(unit in MemoryUnit,
      where:
        unit.id in ^unit_ids and is_nil(unit.consolidated_at) and
          is_nil(unit.consolidation_failed_at),
      select: unit.id,
      lock: "FOR UPDATE"
    )
    |> repo.all(repo_opts)
  end

  @doc "Identity + version of the pooled observations a merge plan was built against."
  def observation_fingerprint(observations) do
    observations
    |> Enum.map(&{&1.id, &1.updated_at})
    |> Enum.sort()
  end

  @doc """
  Hindsight's observation capacity note (consolidator.py:1520-1536): when a scope is
  at or near `max_observations_per_scope`, tell the merge model so it prefers UPDATE
  over CREATE. `nil` when no cap is configured or the scope has ample room.
  """
  def capacity_note(:unlimited, _cap, _fact_count), do: nil

  def capacity_note(0, cap, _fact_count) do
    "OBSERVATION LIMIT REACHED (#{cap}/#{cap}). Only UPDATE or DELETE existing " <>
      "observations. Do NOT create new ones — merge new knowledge into existing " <>
      "observations via UPDATE."
  end

  def capacity_note(remaining, cap, fact_count) when remaining <= fact_count do
    "This scope has #{remaining} observation slot(s) remaining (out of #{cap}). " <>
      "Prefer UPDATE over CREATE when possible."
  end

  def capacity_note(_remaining, _cap, _fact_count), do: nil

  defp schema_max_creates(:unlimited), do: nil
  defp schema_max_creates(remaining), do: remaining

  @doc "Stamp `consolidated_at = now` on the given source facts so they are not reprocessed."
  def stamp_consolidated!(_repo, [], _repo_opts), do: {0, nil}

  def stamp_consolidated!(repo, unit_ids, repo_opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repo.update_all(
      from(unit in MemoryUnit, where: unit.id in ^unit_ids),
      [set: [consolidated_at: now]],
      repo_opts
    )
  end

  @doc """
  Quarantine facts that a size-1 LLM merge could not process. Stamps
  `consolidation_failed_at = now`, excluding them from the pending query
  thereafter (Hindsight consolidator.py:509-513). Only reached after bisection
  has isolated the poison fact, so the rest of a batch still consolidates.
  """
  def stamp_consolidation_failed!(_repo, [], _repo_opts), do: {0, nil}

  def stamp_consolidation_failed!(repo, unit_ids, repo_opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repo.update_all(
      from(unit in MemoryUnit, where: unit.id in ^unit_ids),
      [set: [consolidation_failed_at: now]],
      repo_opts
    )
  end

  @doc """
  Resolve the source facts backing a set of pooled observations so their text +
  dates can be serialized into the merge prompt (Hindsight
  `_build_observations_for_llm`). Returns a `%{id_string => MemoryUnit}` map.
  """
  def resolve_source_facts(_repo, _bank_id, [], _repo_opts), do: %{}

  def resolve_source_facts(repo, bank_id, source_ids, repo_opts) do
    ids = source_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    from(unit in MemoryUnit, where: unit.bank_id == ^bank_id and unit.id in ^ids)
    |> repo.all(repo_opts)
    |> Map.new(&{to_string(&1.id), &1})
  end

  @doc """
  Resolve the per-scope LLM batch size (facts per merge call). Bank config
  override wins, else the engine default, else Hindsight's default of 8
  (consolidator.py:257, config.py:604). Foresight previously sent an entire
  scope in one call — this bounds each merge call for JSON reliability.
  """
  def llm_batch_size(bank) do
    raw =
      get_in(bank_config(bank), ["consolidation_llm_batch_size"]) ||
        Foresight.Config.get(:engine, :consolidation_llm_batch_size, 8)

    # F2 (audit): mirror Hindsight `max(1, config.consolidation_llm_batch_size)`
    # (consolidator.py:257) — a non-positive configured size floors to 1, not the
    # default 8; only a missing/non-integer value falls back to the default.
    case raw do
      size when is_integer(size) -> max(1, size)
      _ -> 8
    end
  end

  @default_max_attempts 3

  @doc """
  How many times to retry a failing LLM merge for a batch BEFORE the orchestration
  bisects it. Mirror of Hindsight `consolidation_max_attempts` (default 3,
  consolidator.py:1286). Bank override wins, else engine config, else 3.
  """
  def max_attempts(bank) do
    raw =
      get_in(bank_config(bank), ["consolidation_max_attempts"]) ||
        Foresight.Config.get(:engine, :consolidation_max_attempts, @default_max_attempts)

    case raw do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_attempts
    end
  end

  # ---- mental model refresh (adapted to multi-observation scope) -------------

  def refresh_mental_model!(
        repo,
        bank,
        scope_key,
        scope_observations,
        units,
        repo_opts,
        bank_document_record_fun
      )
      when is_function(bank_document_record_fun, 4) do
    external_id = mental_model_external_id(scope_key)
    tags = scope_tags(scope_key)

    text =
      scope_observations
      |> Enum.map(& &1.content)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    attrs = %{
      bank_id: bank.id,
      external_id: external_id,
      title: mental_model_title(tags),
      original_text: text,
      tags: tags,
      metadata: %{
        "document_type" => "mental_model",
        "scope_key" => scope_key,
        "observation_ids" => Enum.map(scope_observations, &to_string(&1.id)),
        "source_memory_ids" => Enum.map(units, &to_string(&1.id)),
        "source_fact_ids" => source_fact_ids_for_units(units)
      }
    }

    repo
    |> bank_document_record_fun.(bank.id, external_id, repo_opts)
    |> Document.changeset(attrs)
    |> repo.insert_or_update!(repo_opts)
  end

  # ---- LLM merge (degrade-safe) ----------------------------------------------

  defp llm_merge(llm, bank, scope_key, units, existing_obs, opts, source_facts) do
    mission = bank_mission(bank)
    facts_text = ConsolidationPrompt.format_facts(units)
    serialized_obs = serialize_observations(existing_obs, source_facts)

    observations_text = ConsolidationPrompt.format_observations(serialized_obs)

    # Slot-cap fidelity: tell the model when the scope is at or near its cap and
    # constrain its `creates` to the remaining slots, instead of only truncating
    # afterwards (Hindsight consolidator.py:1520-1546).
    remaining = create_slots(bank, existing_obs, [])
    capacity_note = capacity_note(remaining, max_observations_per_scope(bank), length(units))
    schema = ConsolidationPrompt.schema(schema_max_creates(remaining))

    messages =
      ConsolidationPrompt.messages(mission, facts_text, observations_text, capacity_note)

    prompt = %{
      query: "consolidate",
      mission: mission,
      scope_key: scope_key,
      facts:
        Enum.map(units, &%{"id" => to_string(&1.id), "content" => &1.content, "tags" => &1.tags}),
      observations: serialized_obs
    }

    # F1 (audit): retry the SAME batch up to `max_attempts` before giving up, so a
    # transient JSON hiccup doesn't immediately force the orchestration to bisect.
    # Mirrors Hindsight's inner `for attempt in range(1, max_attempts + 1)` loop
    # (consolidator.py:1300) which precedes adaptive bisection. Only a batch that
    # fails every attempt returns {:skip} (then the orchestration bisects).
    case safe_complete_with_retries(
           llm,
           prompt,
           messages,
           schema,
           opts,
           max_attempts(bank),
           scope_key
         ) do
      {:ok, response} ->
        {:ok, normalize_ops(response)}

      {:error, reason} ->
        # A skip leaves the scope's facts pending (retryable) and writes no
        # observation. This was silent before the fix and hid a whole class of
        # structured-output parse failures (local models fencing/drifting their
        # merge JSON), which is why consolidation produced zero observations
        # while looking healthy. Make it loud.
        Logger.warning(
          "consolidation merge skipped for scope #{inspect(scope_key)} " <>
            "(#{length(units)} facts) after #{max_attempts(bank)} attempts: #{inspect(reason)}"
        )

        # "Make it loud" was right but insufficient: a log line cannot be asserted on.
        # An earlier head-to-head skipped 5 merges and would still have printed a
        # scoreboard. Emit it so an eval harness can refuse to score a degraded arm.
        :telemetry.execute(
          [:foresight, :consolidation, :merge_skipped],
          %{count: 1, facts: length(units)},
          %{scope_key: scope_key, reason: reason}
        )

        {:skip, reason}
    end
  end

  defp safe_complete_with_retries(llm, prompt, messages, schema, opts, attempts, scope_key) do
    Enum.reduce_while(1..attempts, {:error, :not_attempted}, fn attempt, _acc ->
      case safe_complete(llm, prompt, messages, schema, opts) do
        {:ok, response} ->
          {:halt, {:ok, response}}

        {:error, reason} when attempt < attempts ->
          Logger.warning(
            "consolidation merge attempt #{attempt}/#{attempts} failed for scope " <>
              "#{inspect(scope_key)} (#{inspect(reason)}); retrying"
          )

          {:cont, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_complete(llm, prompt, messages, schema, opts) do
    case llm.complete_json_schema(prompt, messages, schema, llm_opts(opts)) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        # Recover from local-LLM fenced / trailing-comma JSON (same failure mode
        # the retain extractor hits) before giving up and leaving facts pending.
        case StructuredRecovery.recover(reason) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, reason}
        end
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp llm_opts(opts) do
    # Consolidation may target a JSON-reliable model distinct from the reader/
    # reflect LLM (an explicit :consolidation_provider_opts wins; otherwise the
    # engine provider_opts apply). Drop nils so LlmCore's Keyword.merge onto the
    # engine config doesn't crash.
    provider_opts =
      Keyword.get(opts, :consolidation_provider_opts) || Keyword.get(opts, :provider_opts)

    [
      provider: Keyword.get(opts, :provider),
      provider_opts: provider_opts,
      sleep_ms: Keyword.get(opts, :sleep_ms),
      usage_role: :consolidate
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp normalize_ops(response) when is_map(response) do
    %{
      "creates" => normalize_list(response["creates"] || response[:creates]),
      "updates" => normalize_list(response["updates"] || response[:updates]),
      "deletes" => normalize_list(response["deletes"] || response[:deletes])
    }
  end

  defp normalize_ops(_other), do: %{"creates" => [], "updates" => [], "deletes" => []}

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp normalize_list(_other), do: []

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify_keys(other), do: other

  # ---- delete/update/create preparation --------------------------------------

  defp prepare_deletes(deletes, obs_by_id) do
    deletes
    |> List.wrap()
    |> Enum.map(&Map.get(obs_by_id, to_string(&1["observation_id"])))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp prepare_updates(updates, obs_by_id, units, fact_ids, embedder, deleted_ids) do
    units_by_id = Map.new(units, &{to_string(&1.id), &1})

    updates
    |> List.wrap()
    |> dedupe_updates()
    |> Enum.reject(&MapSet.member?(deleted_ids, to_string(&1["observation_id"])))
    |> Enum.map(fn update ->
      observation = Map.get(obs_by_id, to_string(update["observation_id"]))
      source_units = resolve_source_units(update["source_fact_ids"], units_by_id, fact_ids)
      build_update(observation, update["text"], source_units, embedder)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp prepare_creates(creates, units, fact_ids, embedder, remaining) do
    units_by_id = Map.new(units, &{to_string(&1.id), &1})

    creates
    |> List.wrap()
    |> maybe_truncate(remaining)
    |> Enum.map(fn create ->
      source_units = resolve_source_units(create["source_fact_ids"], units_by_id, fact_ids)
      build_create(create["text"], source_units, embedder)
    end)
    |> Enum.reject(&is_nil/1)
  end

  # AT MOST ONE update per observation_id — keep last text, union source_fact_ids.
  defp dedupe_updates(updates) do
    updates
    |> Enum.reduce({[], %{}}, fn update, {order, acc} ->
      id = to_string(update["observation_id"])

      merged =
        case Map.get(acc, id) do
          nil ->
            update

          existing ->
            %{
              "observation_id" => id,
              "text" => update["text"] || existing["text"],
              "source_fact_ids" =>
                Enum.uniq(
                  List.wrap(existing["source_fact_ids"]) ++ List.wrap(update["source_fact_ids"])
                )
            }
        end

      order = if Map.has_key?(acc, id), do: order, else: [id | order]
      {order, Map.put(acc, id, merged)}
    end)
    |> then(fn {order, acc} -> order |> Enum.reverse() |> Enum.map(&Map.fetch!(acc, &1)) end)
  end

  defp build_update(nil, _text, _source_units, _embedder), do: nil
  # No live source facts (all source_fact_ids hallucinated/out-of-batch) → skip,
  # matching Hindsight's _filter_live_source_memories "if none, skip" guard.
  defp build_update(_observation, _text, [], _embedder), do: nil

  defp build_update(observation, text, source_units, embedder) do
    text = clean_text(text) || observation.content
    live_source_ids = Enum.map(source_units, & &1.id)
    # Union of prior evidence with the new source facts (concat-then-dedupe).
    source_ids = Enum.uniq((observation.source_memory_ids || []) ++ live_source_ids)
    merged_tags = Enum.uniq((observation.tags || []) ++ source_tags(source_units))

    embed =
      embed_observation(
        embedder,
        text,
        source_units,
        observation.embedded_by,
        observation.embedded_dim
      )

    history_entry = %{
      "previous_text" => observation.content,
      "previous_tags" => observation.tags || [],
      "changed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "new_source_memory_ids" => Enum.map(live_source_ids, &to_string/1)
    }

    metadata =
      observation.metadata
      |> Kernel.||(%{})
      |> Map.update("history", [history_entry], &(List.wrap(&1) ++ [history_entry]))

    attrs =
      %{
        content: text,
        tags: merged_tags,
        metadata: metadata,
        # proof_count tracks total evidence for an UPDATE (Hindsight: len(source_ids)).
        proof_count: length(source_ids),
        source_memory_ids: source_ids,
        occurred_start: min_datetime([observation.occurred_start | starts(source_units)]),
        occurred_end: max_datetime([observation.occurred_end | ends(source_units)]),
        mentioned_at:
          max_datetime([observation.mentioned_at | mentioned(source_units)]) ||
            DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }
      |> merge_embedding(embed)

    %{observation: observation, attrs: attrs}
  end

  # No live source facts → skip, so a hallucinated fact id cannot mint an
  # untagged, sourceless observation that escapes the tag-scope boundary.
  defp build_create(_text, [], _embedder), do: nil

  defp build_create(text, source_units, embedder) do
    case clean_text(text) do
      nil ->
        nil

      clean ->
        live_source_ids = Enum.map(source_units, & &1.id)
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        embed = embed_observation(embedder, clean, source_units, nil, nil)

        attrs =
          %{
            fact_type: :observation,
            content: clean,
            context: "consolidation",
            tags: source_tags(source_units),
            metadata: %{"generated_by" => "consolidation"},
            # Hindsight writes proof_count=1 on CREATE (SQL literal), regardless of
            # source count; UPDATE later grows it to len(source_ids). Mirrored for parity.
            proof_count: 1,
            source_memory_ids: live_source_ids,
            occurred_at: min_datetime(starts(source_units)) || now,
            occurred_start: min_datetime(starts(source_units)),
            occurred_end: max_datetime(ends(source_units)),
            mentioned_at: max_datetime(mentioned(source_units)) || now
          }
          |> merge_embedding(embed)

        %{attrs: attrs}
    end
  end

  # ---- embedding (fixes the zero-vector bug) ---------------------------------

  # Observations were previously written with a zero vector (embedded_by
  # "consolidation") and were therefore invisible to semantic recall. We now
  # embed the observation TEXT with the same profile as its source facts.
  defp embed_observation(embedder, text, source_units, fallback_model, fallback_dim) do
    {dim, model_id} = source_embedding_profile(source_units, fallback_model, fallback_dim)
    profile = %{"model_id" => model_id, "embedding_dim" => dim}

    case embedder.embed(text, EmbeddingProfile.embedder_opts(profile)) do
      {:ok, values} ->
        %{
          embedded_by: model_id,
          embedded_dim: dim,
          vector_field: EmbeddingProfile.vector_field(dim),
          vector: EmbeddingProfile.to_vector(dim, values)
        }

      _other ->
        # Never block a write on an embedding failure; fall back to a zero vector
        # (the row is still created/updated, just not semantically recallable
        # until re-embedded). This should be rare — the embedder is local.
        %{
          embedded_by: model_id,
          embedded_dim: dim,
          vector_field: EmbeddingProfile.vector_field(dim),
          vector: EmbeddingProfile.to_vector(dim, List.duplicate(0.0, dim))
        }
    end
  end

  defp merge_embedding(attrs, embed) do
    attrs
    |> Map.put(:embedded_by, embed.embedded_by)
    |> Map.put(:embedded_dim, embed.embedded_dim)
    |> Map.put(embed.vector_field, embed.vector)
  end

  defp source_embedding_profile(source_units, fallback_model, fallback_dim) do
    dim =
      Enum.find_value(source_units, fallback_dim || @default_embedded_dim, fn unit ->
        case unit.embedded_dim do
          d when is_integer(d) and d > 0 -> d
          _ -> nil
        end
      end)

    model_id =
      Enum.find_value(source_units, fallback_model, fn unit ->
        case unit.embedded_by do
          m when is_binary(m) and m != "" -> m
          _ -> nil
        end
      end) || "consolidation"

    {dim, model_id}
  end

  # ---- slot cap --------------------------------------------------------------

  # max_observations_per_scope (0/absent → uncapped). remaining = cap - live obs
  # after deletes; creates beyond that are dropped (updates/deletes always apply).
  # delete_count uses the RESOLVED deletes (hallucinated/duplicate delete ids were
  # already dropped by prepare_deletes) so the cap can't be overshot.
  defp create_slots(bank, existing_obs, deletes) do
    case max_observations_per_scope(bank) do
      cap when is_integer(cap) and cap > 0 ->
        max(cap - max(length(existing_obs) - length(deletes), 0), 0)

      _ ->
        :unlimited
    end
  end

  defp maybe_truncate(creates, :unlimited), do: creates
  defp maybe_truncate(creates, remaining), do: Enum.take(creates, remaining)

  defp max_observations_per_scope(bank) do
    get_in(bank_config(bank), ["max_observations_per_scope"]) ||
      Foresight.Config.get(:engine, :max_observations_per_scope, 0)
  end

  # ---- serialization for the prompt ------------------------------------------

  @doc """
  Serialize pooled observations for the LLM merge prompt. Mirrors Hindsight's
  `_build_observations_for_llm` (consolidator.py:1190-1226): each observation
  carries `id`, `text`, `proof_count`, its temporal range, `mentioned_at`, and a
  `source_memories` array (the supporting facts' text + dates, resolved from
  `source_memory_ids` via `source_facts_by_id`). Temporal fields and
  `source_memories` are only emitted when present so the prompt stays lean.
  """
  def serialize_observations(observations, source_facts_by_id \\ %{}) do
    Enum.map(observations, fn obs ->
      %{
        "id" => to_string(obs.id),
        "text" => obs.content,
        # F3 (audit): floor at 1 to match Hindsight's `len(...) or 1`
        # (consolidator.py:1200) — a valid observation always advertises ≥1 proof.
        "proof_count" => max(obs.proof_count || length(obs.source_memory_ids || []), 1)
      }
      |> put_iso("occurred_start", obs.occurred_start)
      |> put_iso("occurred_end", obs.occurred_end)
      |> put_iso("mentioned_at", obs.mentioned_at)
      |> put_source_memories(obs, source_facts_by_id)
    end)
  end

  defp put_source_memories(map, obs, source_facts_by_id) do
    source_memories =
      (obs.source_memory_ids || [])
      |> Enum.map(&Map.get(source_facts_by_id, to_string(&1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&serialize_source_memory/1)

    case source_memories do
      [] -> map
      list -> Map.put(map, "source_memories", list)
    end
  end

  defp serialize_source_memory(fact) do
    %{"text" => fact.content}
    |> put_present("context", fact.context)
    |> put_iso("occurred_start", fact.occurred_start)
    |> put_iso("occurred_end", fact.occurred_end)
    |> put_iso("mentioned_at", fact.mentioned_at)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_iso(map, _key, nil), do: map
  defp put_iso(map, key, %DateTime{} = dt), do: Map.put(map, key, DateTime.to_iso8601(dt))
  defp put_iso(map, key, value), do: Map.put(map, key, value)

  defp resolve_source_units(source_fact_ids, units_by_id, fact_ids) do
    source_fact_ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&MapSet.member?(fact_ids, &1))
    |> Enum.map(&Map.get(units_by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  # ---- scope-key helpers (public: used across storage/ecto.ex) ---------------

  def scope_key_for_item(item) when is_map(item) do
    build_scope_key(List.wrap(item["tags"]), normalize_observation_scopes(item))
  end

  def normalize_observation_scopes(item) when is_map(item) do
    item
    |> Map.get("observation_scopes", get_in(item, ["metadata", "observation_scopes"]) || %{})
    |> normalize_scope_map()
  end

  def normalize_observation_scopes(_item), do: %{}

  def requested_scope_keys(payload) do
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

  defp batch_size(payload) do
    case payload["batch_size"] do
      size when is_integer(size) and size > 0 -> size
      _ -> Foresight.Config.get(:engine, :consolidation_batch_size, @default_batch_size)
    end
  end

  defp source_fact_ids_for_units(units) do
    units
    |> Enum.flat_map(fn unit ->
      case Enum.map(unit.source_memory_ids || [], &to_string/1) do
        [] -> [to_string(unit.id)]
        ids -> ids
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scope_key_for_unit(%MemoryUnit{} = unit) do
    build_scope_key(unit.tags || [], unit.observation_scopes || %{})
  end

  defp normalize_tag_scope(tags) do
    tags
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
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

  defp scope_tags("__untagged__"), do: []

  defp scope_tags(scope_key) do
    scope_key
    |> String.split("##", parts: 2)
    |> List.first()
    |> case do
      "__untagged__" -> []
      key -> String.split(key, "||", trim: true)
    end
  end

  defp mental_model_external_id(scope_key), do: @mental_model_prefix <> scope_key

  defp mental_model_title([]), do: "Mental Model"
  defp mental_model_title(tags), do: "Mental Model: " <> Enum.join(tags, ", ")

  # ---- temporal helpers ------------------------------------------------------

  defp starts(units),
    do: Enum.map(units, &(&1.occurred_start || &1.occurred_at || &1.mentioned_at))

  defp ends(units), do: Enum.map(units, &(&1.occurred_end || &1.occurred_at || &1.mentioned_at))
  defp mentioned(units), do: Enum.map(units, & &1.mentioned_at)

  defp min_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.min_by(list, &DateTime.to_unix(&1, :microsecond))
    end
  end

  defp max_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.max_by(list, &DateTime.to_unix(&1, :microsecond))
    end
  end

  defp source_tags(units) do
    units
    |> Enum.flat_map(&(&1.tags || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp clean_text(nil), do: nil

  defp clean_text(text) when is_binary(text) do
    case text |> Sanitize.llm_output() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_text(_other), do: nil

  # ---- bank config -----------------------------------------------------------

  defp bank_mission(bank) do
    Map.get(bank, :mission) || Map.get(bank, :observations_mission) ||
      get_in(bank_config(bank), ["observations_mission"])
  end

  defp bank_config(bank) do
    case Map.get(bank, :config_overrides) do
      %{} = config -> config
      _ -> %{}
    end
  end
end
