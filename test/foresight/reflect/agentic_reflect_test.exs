defmodule Foresight.Reflect.AgenticReflectTest do
  @moduledoc """
  Verifies the agentic reflect path: when the LLM supports native
  tool-calling, reflect runs the LlmCore.Agent.Loop (retrieve via tools → answer),
  and falls back to the fixed structured pipeline otherwise.

  Real Postgres via PostgresHarness — tagged :tier2.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Migrator
  alias Foresight.Context
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Storage.Ecto, as: StorageEcto
  alias Foresight.TestSupport.FakeDoneLLM
  alias Foresight.TestSupport.FakeLLM
  alias Foresight.TestSupport.FakeObservationSearchLLM
  alias Foresight.TestSupport.FakeToolCallingLLM
  alias Foresight.TestSupport.PostgresHarness

  @moduletag :tier2
  @moduletag timeout: 120_000

  setup_all do
    harness = PostgresHarness.start!()
    repo_config = Application.get_env(:foresight, Foresight.Repo, [])

    Application.put_env(
      :foresight,
      Foresight.Repo,
      Keyword.merge(repo_config, url: harness.url, pool_size: 5)
    )

    start_supervised!(Foresight.Repo)
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)

    migrations_path = Path.expand("../../../priv/repo/migrations", __DIR__)

    {:ok, _migrated, _apps} =
      Migrator.with_repo(Foresight.Repo, fn repo ->
        Migrator.run(repo, migrations_path, :up, all: true)
      end)

    on_exit(fn ->
      Application.put_env(:foresight, Foresight.Repo, repo_config)
      PostgresHarness.stop!(harness)
    end)

    :ok
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)
    put_engine(FakeToolCallingLLM)

    on_exit(fn ->
      restore(:backend, original_backend)
      restore(:engine, original_engine)
    end)

    :ok
  end

  defmodule ProviderErrorLLM do
    @moduledoc "Fixed-path LLM (no complete_with_tools) whose calls fail like a downed provider."
    @behaviour Foresight.LLM

    @impl true
    def complete_structured(_prompt, _messages, _module, _opts),
      do: {:error, LlmCore.LLM.Error.new(:provider_error, message: "model unloaded")}

    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:error, LlmCore.LLM.Error.new(:provider_error, message: "model unloaded")}
  end

  test "reflect degrades to {:error, _} when the LLM provider fails (no crash / no leaked tuple)" do
    ctx = %Context{tenant_id: "err-tenant", mode: :mode_a, bank: "err-bank"}
    put_engine(ProviderErrorLLM)

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [%{"content" => "the sky is blue", "context" => "chat", "type" => "world"}]
      })

    # Fixed-path reflect (ProviderErrorLLM exports no complete_with_tools) hits a
    # provider error on the planner call. It must return a clean error tuple, not
    # raise a CaseClauseError or leak the raw {{:error, _}, ms} tuple.
    assert {:error, %Foresight.Error{}} =
             Foresight.reflect(ctx, %{"query" => "what colour is the sky?"})
  end

  defmodule ExhaustingToolLLM do
    @moduledoc """
    Agentic LLM that NEVER answers in plain text while tools are offered — it always
    emits a `recall` tool call, so the loop runs to `max_iterations` and returns
    `{:error, :max_iterations_reached}`. On a tools-less call (the forced final
    synthesis) it returns a grounded answer. This reproduces the Mode-B failure the
    bench surfaced: the loop gathered evidence, then exhausted.
    """
    @behaviour Foresight.LLM
    alias LlmCore.LLM.Response

    @synth "FORCED_SYNTHESIS_ANSWER: the sky is blue, from gathered evidence."

    def synth_answer, do: @synth

    @impl true
    def complete_with_tools(_messages, opts) do
      case Keyword.get(opts, :tools, []) do
        [] ->
          {:ok, Response.new(content: @synth, tool_calls: nil)}

        _offered ->
          {:ok,
           Response.new(
             content: nil,
             tool_calls: [
               %LlmToolkit.Tool.Call{
                 id: "call_x",
                 name: "recall",
                 arguments: %{"reason" => "gather", "query" => "sky color"}
               }
             ]
           )}
      end
    end

    @impl true
    def complete_structured(prompt, messages, module, opts),
      do: Foresight.TestSupport.FakeLLM.complete_structured(prompt, messages, module, opts)

    @impl true
    def complete_json_schema(prompt, messages, schema, opts),
      do: Foresight.TestSupport.FakeLLM.complete_json_schema(prompt, messages, schema, opts)
  end

  test "on agentic loop exhaustion, reflect synthesizes from gathered evidence (never discards it)" do
    # Mode B: the loop retrieved (recall pre-seed + tool recalls) but never
    # emitted a plain-text answer, so it exhausted max_iterations. The OLD behaviour
    # fell back to a fresh reflect_fixed_once that re-recalled from scratch and
    # returned no_evidence_reflect_text — DISCARDING the gathered evidence. Faithful
    # to Hindsight's forced-final-synthesis, reflect must instead answer from what
    # the loop already gathered.
    put_engine(ExhaustingToolLLM)
    ctx = %Context{tenant_id: "exhaust-tenant", mode: :mode_a, bank: "exhaust-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "the sky is blue", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is the sky?"})

    refute result["text"] =~ "don't have enough grounded information",
           "must not discard gathered evidence and fall back to the no-evidence text"

    assert result["text"] == ExhaustingToolLLM.synth_answer()
    assert get_in(result, ["trace", "termination"]) == "forced_synthesis"
    assert result["memory_ids"] != []
  end

  test "agentic pre-seed recall is NOT starved by the answer's max_tokens" do
    # The reflect payload's max_tokens caps the ANSWER length, but it was leaking into
    # the pre-seed recall's trim budget (and every tool recall), starving the evidence
    # the model reasons over — the direct cause of multi-session UNDER-counting (reflect
    # saw fewer facts than the fixed arm despite "pre-seeding everything"). A tiny answer
    # cap must not shrink the retrieved evidence.
    ctx = %Context{tenant_id: "budget-tenant", mode: :mode_a, bank: "budget-bank"}

    items =
      for i <- 1..4,
          do: %{
            "content" => "kitchen item number #{i} was replaced",
            "context" => "chat",
            "type" => "world"
          }

    assert {:ok, _} = Foresight.retain(ctx, %{"async" => false, "items" => items})

    # max_tokens: 10 would trim recall to a single item under the old (conflated)
    # behaviour; decoupled, all four retained facts reach the agent as grounding.
    assert {:ok, result} =
             Foresight.reflect(ctx, %{
               "query" => "how many kitchen items were replaced?",
               "max_tokens" => 10
             })

    assert length(result["memory_ids"]) == 4,
           "answer cap must not starve evidence; got #{length(result["memory_ids"])} grounded memories"
  end

  test "fixed-path reflect recall is NOT starved by the answer's max_tokens (audit MAJOR)" do
    # reflect_fixed_once (the fallback / budget:low path) passed the raw payload to
    # recall, so a tiny answer max_tokens starved the evidence feeding the plan +
    # synthesis — the same bug the agentic path had (fixed there but missed here).
    # FakeLLM exports no complete_with_tools, forcing the fixed pipeline.
    put_engine(FakeLLM)
    ctx = %Context{tenant_id: "fixed-budget-tenant", mode: :mode_a, bank: "fixed-budget-bank"}

    items =
      for i <- 1..4,
          do: %{
            "content" => "distinct fact number #{i} about the topic",
            "context" => "chat",
            "type" => "world"
          }

    assert {:ok, _} = Foresight.retain(ctx, %{"async" => false, "items" => items})

    assert {:ok, result} =
             Foresight.reflect(ctx, %{"query" => "tell me about the topic", "max_tokens" => 10})

    # Sanity: this exercised the fixed path, not agentic.
    refute get_in(result, ["trace", "mode"]) == "agentic"

    # FakeLLM cites up to 2 recalled memory ids. A starved recall (max_tokens 10)
    # collapses to a single item (trim's take-1 floor), so only 1 id can be cited;
    # decoupled, >=2 distinct memories reach synthesis and get grounded.
    assert length(result["memory_ids"]) >= 2,
           "fixed-path answer cap must not starve evidence; got #{length(result["memory_ids"])} grounded"
  end

  test "reflect takes the agentic tool-calling path and answers from retrieved memories" do
    ctx = %Context{tenant_id: "agentic-tenant", mode: :mode_a, bank: "agentic-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "the sky is blue", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is the sky?"})

    assert result["text"] == "AGENTIC_ANSWER: grounded in retrieved memories."
    assert get_in(result, ["trace", "mode"]) == "agentic"
    # Grounding is populated from the forced pre-seed + the loop's recall tool call.
    assert result["memory_ids"] != []

    # Every cited memory id must have a matching based_on.memories entry (the
    # agentic path must not report ids it can't describe).
    based_on_ids =
      get_in(result, ["based_on", "memories"])
      |> Enum.map(&to_string(&1["id"]))
      |> MapSet.new()

    assert MapSet.subset?(MapSet.new(result["memory_ids"]), based_on_ids)
  end

  test "agentic reflect trace records the REAL tool calls made in the loop (observability)" do
    # The trace previously hardcoded tool_calls => [] and termination => "answered",
    # making the agentic path unobservable — we could not tell "answered from the
    # pre-seed on iteration 1 with zero tools" from "ran real tool-calling". That
    # blindness hid the multi-session under-retrieval gap. The trace must
    # report the actual tool calls the loop executed.
    ctx = %Context{tenant_id: "trace-tenant", mode: :mode_a, bank: "trace-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "the sky is blue", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is the sky?"})

    tool_calls = get_in(result, ["trace", "tool_calls"])
    assert is_list(tool_calls)

    # FakeToolCallingLLM issues exactly one `recall` tool call before answering.
    assert Enum.any?(tool_calls, fn tc -> (tc["tool"] || tc[:tool]) == "recall" end),
           "agentic trace must record the recall tool call, got: #{inspect(tool_calls)}"

    # And the tools-called count must reflect reality, not the hardcoded default.
    assert get_in(result, ["trace", "tools_called"]) == 1
  end

  test "agentic reflect result reports summed token usage from the loop's LLM calls " do
    # The now-DEFAULT agentic path hardcoded usage => %{}, zeroing token/cost
    # accounting for reflect (the input the per-tenant cost reporting needs).
    # FakeToolCallingLLM emits usage on both loop calls (tool-call 100/20, answer
    # 150/30); the result must report the SUM across the loop, not the last call.
    ctx = %Context{tenant_id: "usage-tenant", mode: :mode_a, bank: "usage-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "the sky is blue", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is the sky?"})
    assert get_in(result, ["trace", "mode"]) == "agentic"

    usage = result["usage"]
    assert usage["input_tokens"] == 250, "summed prompt tokens across both loop calls"
    assert usage["output_tokens"] == 50, "summed completion tokens across both loop calls"
    assert usage["total_tokens"] == 300
  end

  test "agentic reflect finishes via the terminal done tool with LLM-selected citations " do
    # Faithful to Hindsight: the model ends by calling `done` with its answer + the
    # ids it actually used (llm_core terminal_tool). The answer comes from the done
    # args (response.content is nil), and citations are filtered to retrieved-and-
    # cited — so a hallucinated id is dropped, and the pre-seeded-but-uncited memory
    # is NOT force-cited (the over-citation the all-retrieved path produced).
    put_engine(FakeDoneLLM)
    ctx = %Context{tenant_id: "done-tenant", mode: :mode_a, bank: "done-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "the sky is blue", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is the sky?"})

    assert get_in(result, ["trace", "mode"]) == "agentic"
    assert result["text"] == FakeDoneLLM.answer()

    # done cited only "ghost-id-not-retrieved"; filtered vs retrieved => empty. The
    # all-retrieved fallback would have force-cited the pre-seeded memory instead.
    assert result["memory_ids"] == []
    assert get_in(result, ["based_on", "memories"]) == []
  end

  test "reflect falls back to the fixed pipeline when the llm cannot tool-call" do
    put_engine(FakeLLM)
    ctx = %Context{tenant_id: "fixed-tenant", mode: :mode_a, bank: "fixed-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "grass is green", "context" => "chat", "type" => "world"}
               ]
             })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what color is grass?"})

    refute get_in(result, ["trace", "mode"]) == "agentic"
    assert is_binary(result["text"])
  end

  test "search_observations surfaces an observation by semantic relevance where keyword recall misses" do
    ctx = %Context{tenant_id: "obs-sem-tenant", mode: :mode_a, bank: "obs-sem-bank"}
    opts = Application.get_env(:foresight, :engine)

    # A probe fact establishes the embedding-profile stamps (embedded_by /
    # embedded_dim) that recall_base_query filters on, without hard-coding the
    # resolved model id.
    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [%{"content" => "seed fact", "context" => "chat", "type" => "world"}]
             })

    probe =
      Foresight.Repo.one!(
        from(u in MemoryUnit, where: u.bank_id == ^ctx.bank and u.fact_type == :world, limit: 1)
      )

    # Content shares NO tokens with the query "team velocity".
    obs =
      insert_observation!(
        ctx.bank,
        "crew shipped four deliverables during spring",
        ["scope:velocity"],
        probe
      )

    # Semantic path (the NEW tool wiring): retrieves the observation despite zero
    # keyword overlap.
    assert {:ok, %{"results" => results}} =
             StorageEcto.recall(
               ctx,
               %{
                 "query" => "team velocity",
                 "types" => ["observation"],
                 "tags" => ["scope:velocity"]
               },
               opts
             )

    assert Enum.any?(results, &(to_string(&1["id"]) == to_string(obs.id))),
           "semantic observation recall must surface the consolidated observation"

    # Keyword path (the OLD tool wiring): misses it — no lexical overlap.
    assert {:ok, %{"items" => items}} =
             StorageEcto.list_memories(
               ctx,
               %{"type" => "observation", "q" => "team velocity", "tags" => ["scope:velocity"]},
               opts
             )

    refute Enum.any?(items, &(to_string(&1["id"]) == to_string(obs.id))),
           "keyword-only observation search must NOT surface a semantically-related-but-lexically-disjoint observation"
  end

  test "observation recall stays within tag scope even when tags_match is unset" do
    ctx = %Context{tenant_id: "obs-iso-tenant", mode: :mode_a, bank: "obs-iso-bank"}
    opts = Application.get_env(:foresight, :engine)

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [%{"content" => "seed fact", "context" => "chat", "type" => "world"}]
             })

    probe =
      Foresight.Repo.one!(
        from(u in MemoryUnit, where: u.bank_id == ^ctx.bank and u.fact_type == :world, limit: 1)
      )

    mine = insert_observation!(ctx.bank, "alpha report", ["scope:mine"], probe)
    theirs = insert_observation!(ctx.bank, "beta report", ["scope:theirs"], probe)

    # No tags_match supplied (the common reflect case). Sub-bank tag scope must
    # still be enforced: only the in-scope observation is returned. Guards the
    # fail-closed match_recall_tags? fix.
    assert {:ok, %{"results" => results}} =
             StorageEcto.recall(
               ctx,
               %{
                 "query" => "team velocity",
                 "types" => ["observation"],
                 "tags" => ["scope:mine"]
               },
               opts
             )

    ids = Enum.map(results, &to_string(&1["id"]))
    assert to_string(mine.id) in ids
    refute to_string(theirs.id) in ids
  end

  test "reflect drives the search_observations tool through the loop and grounds observations" do
    put_engine(FakeObservationSearchLLM)
    ctx = %Context{tenant_id: "obs-loop-tenant", mode: :mode_a, bank: "obs-loop-bank"}

    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [%{"content" => "seed fact", "context" => "chat", "type" => "world"}]
             })

    probe =
      Foresight.Repo.one!(
        from(u in MemoryUnit, where: u.bank_id == ^ctx.bank and u.fact_type == :world, limit: 1)
      )

    _obs = insert_observation!(ctx.bank, "quarterly output summary", ["scope:q"], probe)

    assert {:ok, result} =
             Foresight.reflect(ctx, %{
               "query" => "how productive was the team?",
               "tags" => ["scope:q"]
             })

    assert result["text"] == "OBSERVATION_ANSWER: grounded in consolidated observations."
    assert get_in(result, ["trace", "mode"]) == "agentic"
    assert result["observation_ids"] != []
  end

  defp insert_observation!(bank, content, tags, probe) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    # All-ones matches FakeEmbedder's embedding for any non-empty text, so the
    # observation clears the semantic-similarity floor against the query vector.
    vector = 1.0 |> List.duplicate(probe.embedded_dim) |> Pgvector.new()

    attrs =
      %{
        bank_id: bank,
        fact_type: :observation,
        content: content,
        context: "consolidated",
        tags: tags,
        proof_count: 2,
        source_memory_ids: [probe.id],
        embedded_by: probe.embedded_by,
        embedded_dim: probe.embedded_dim,
        occurred_at: now,
        mentioned_at: now
      }
      |> Map.put(vector_field_name(probe.embedded_dim), vector)

    %MemoryUnit{}
    |> MemoryUnit.changeset(attrs)
    |> Foresight.Repo.insert!()
  end

  # -- grounded reflect -----------------------------------------------

  # Marks any clause containing "UNGROUNDED" as unsupported; everything else supported.
  defmodule ReentryGroundingVerifier do
    @behaviour Foresight.Reflect.EntailmentVerifier

    @impl true
    def verify(clauses, _evidence, _opts) do
      Enum.map(clauses, fn c ->
        supported? = not String.contains?(c, "UNGROUNDED")
        %{clause: c, supported?: supported?, score: if(supported?, do: 1.0, else: 0.0)}
      end)
    end
  end

  # Agentic LLM that answers via the done tool: an UNGROUNDED answer on the first pass,
  # then a grounded one once the loop re-enters (detected by the gate's corrective
  # message appearing in history). Proves the gate drives a real correction.
  defmodule ReentryLLM do
    @behaviour Foresight.LLM
    alias LlmCore.LLM.Response

    @ungrounded "The sky is UNGROUNDED plaid."
    @grounded "The sky is blue."
    def ungrounded, do: @ungrounded
    def grounded, do: @grounded

    @impl true
    def complete_with_tools(messages, _opts) do
      answer = if corrective?(messages), do: @grounded, else: @ungrounded

      {:ok,
       Response.new(
         content: nil,
         tool_calls: [
           %LlmToolkit.Tool.Call{
             id: "call_done",
             name: "done",
             arguments: %{
               "answer" => answer,
               "memory_ids" => [],
               "observation_ids" => [],
               "mental_model_ids" => []
             }
           }
         ],
         usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
       )}
    end

    defp corrective?(messages) do
      Enum.any?(messages, fn m ->
        content = (is_map(m) && (Map.get(m, :content) || Map.get(m, "content"))) || ""
        is_binary(content) and String.contains?(content, "Grounding check:")
      end)
    end

    @impl true
    def complete_structured(p, m, mod, o),
      do: Foresight.TestSupport.FakeLLM.complete_structured(p, m, mod, o)

    @impl true
    def complete_json_schema(p, m, s, o),
      do: Foresight.TestSupport.FakeLLM.complete_json_schema(p, m, s, o)
  end

  # recall → expand (depth taken from a named Agent, since reflect may run the LLM
  # in its own task) → plain-text answer. Stashes the expand tool result it is
  # shown so the test can inspect what the model saw.
  defmodule ExpandingLLM do
    @behaviour Foresight.LLM
    alias LlmCore.LLM.Response

    def start_link(_opts),
      do: Agent.start_link(fn -> %{depth: "chunk", result: nil} end, name: __MODULE__)

    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    def set_depth(depth), do: Agent.update(__MODULE__, &%{&1 | depth: depth, result: nil})
    def result, do: Agent.get(__MODULE__, & &1.result)

    @impl true
    def complete_with_tools(messages, _opts) do
      tool_results = messages |> Enum.filter(&(role(&1) == :tool)) |> Enum.map(&content/1)

      case tool_results do
        [] ->
          {:ok, call("recall", %{"reason" => "gather", "query" => "chunk"})}

        [recall_json] ->
          ids =
            recall_json
            |> Jason.decode!()
            |> Map.get("memories", [])
            |> Enum.map(& &1["id"])

          depth = Agent.get(__MODULE__, & &1.depth)
          {:ok, call("expand", %{"reason" => "context", "memory_ids" => ids, "depth" => depth})}

        [_recall_json, expand_json | _] ->
          Agent.update(__MODULE__, &%{&1 | result: Jason.decode!(expand_json)})
          {:ok, Response.new(content: "chunk two is in the middle", tool_calls: nil, usage: nil)}
      end
    end

    defp call(name, arguments) do
      Response.new(
        content: nil,
        tool_calls: [%LlmToolkit.Tool.Call{id: "call_#{name}", name: name, arguments: arguments}],
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      )
    end

    defp role(message), do: Map.get(message, :role) || Map.get(message, "role")
    defp content(message), do: Map.get(message, :content) || Map.get(message, "content") || ""

    @impl true
    def complete_structured(p, m, mod, o),
      do: Foresight.TestSupport.FakeLLM.complete_structured(p, m, mod, o)

    @impl true
    def complete_json_schema(p, m, s, o),
      do: Foresight.TestSupport.FakeLLM.complete_json_schema(p, m, s, o)
  end

  test "expand honours depth: chunk returns neighbouring chunks, document returns the owning document" do
    put_engine(ExpandingLLM)
    start_supervised!(ExpandingLLM)
    ctx = %Context{tenant_id: "expand-tenant", mode: :mode_a, bank: "expand-bank"}

    items =
      for text <- ["chunk one", "chunk two", "chunk three"] do
        %{
          "content" => text,
          "context" => "doc",
          "document_id" => "doc-exp",
          "document_title" => "Expandable",
          "document_text" => "chunk one\nchunk two\nchunk three"
        }
      end

    assert {:ok, _} = Foresight.retain(ctx, %{"async" => false, "items" => items})

    ExpandingLLM.set_depth("chunk")
    assert {:ok, _} = Foresight.reflect(ctx, %{"query" => "what surrounds chunk two?"})

    assert %{"depth" => "chunk", "expanded" => expanded} = ExpandingLLM.result()
    assert %{"chunk" => chunk} = Enum.find(expanded, &(&1["content"] == "chunk two"))
    assert [%{"id" => before_id, "content" => "chunk one"}] = chunk["before"]
    assert [%{"id" => after_id, "content" => "chunk three"}] = chunk["after"]
    assert {:ok, _} = Ecto.UUID.cast(before_id)
    assert {:ok, _} = Ecto.UUID.cast(after_id)
    assert chunk["total"] == 3

    ExpandingLLM.set_depth("document")
    assert {:ok, _} = Foresight.reflect(ctx, %{"query" => "what surrounds chunk two?"})

    assert %{"depth" => "document", "expanded" => expanded} = ExpandingLLM.result()
    assert %{"document" => document} = Enum.find(expanded, &(&1["content"] == "chunk two"))
    assert document["id"] == "doc-exp"
    assert document["title"] == "Expandable"
    assert document["text"] == "chunk one\nchunk two\nchunk three"
    assert document["truncated"] == false
  end

  # search_mental_models(query from the Agent) → plain-text answer. Stashes the first
  # user message (the pre-seed) and the tool result it is shown.
  defmodule MentalModelSearchingLLM do
    @behaviour Foresight.LLM
    alias LlmCore.LLM.Response

    def start_link(_opts),
      do: Agent.start_link(fn -> %{query: "", preseed: nil, result: nil} end, name: __MODULE__)

    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    def set_query(query), do: Agent.update(__MODULE__, &%{&1 | query: query, result: nil})
    def state, do: Agent.get(__MODULE__, & &1)

    @impl true
    def complete_with_tools(messages, _opts) do
      tool_results = messages |> Enum.filter(&(role(&1) == :tool)) |> Enum.map(&content/1)
      user = messages |> Enum.find(&(role(&1) == :user)) |> content()
      Agent.update(__MODULE__, &%{&1 | preseed: user})

      case tool_results do
        [] ->
          query = Agent.get(__MODULE__, & &1.query)

          {:ok,
           Response.new(
             content: nil,
             tool_calls: [
               %LlmToolkit.Tool.Call{
                 id: "call_mm",
                 name: "search_mental_models",
                 arguments: %{"reason" => "curated first", "query" => query, "max_results" => 1}
               }
             ],
             usage: nil
           )}

        [mm_json | _] ->
          Agent.update(__MODULE__, &%{&1 | result: Jason.decode!(mm_json)})

          {:ok,
           Response.new(content: "answered from the mental model", tool_calls: nil, usage: nil)}
      end
    end

    defp role(message), do: Map.get(message, :role) || Map.get(message, "role")
    defp content(nil), do: ""
    defp content(message), do: Map.get(message, :content) || Map.get(message, "content") || ""

    @impl true
    def complete_structured(p, m, mod, o),
      do: Foresight.TestSupport.FakeLLM.complete_structured(p, m, mod, o)

    @impl true
    def complete_json_schema(p, m, s, o),
      do: Foresight.TestSupport.FakeLLM.complete_json_schema(p, m, s, o)
  end

  test "search_mental_models ranks by embedding similarity, caps results, reports staleness, and seeds the opening context" do
    put_engine(MentalModelSearchingLLM, Foresight.TestSupport.SemanticEmbedder)
    start_supervised!(MentalModelSearchingLLM)
    ctx = %Context{tenant_id: "mm-tenant", mode: :mode_a, bank: "mm-bank"}

    assert {:ok, _} = Foresight.put_bank(ctx, "mm-bank", %{"name" => "MM bank"})

    refreshed = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

    # SemanticEmbedder: "nyc" and "new york city" share a cluster; "android" does not.
    insert_mental_model!("mm-nyc", "NYC guide", "nyc", nil)
    insert_mental_model!("mm-android", "Android notes", "android", refreshed)

    MentalModelSearchingLLM.set_query("new york city")
    assert {:ok, _} = Foresight.reflect(ctx, %{"query" => "new york city"})

    %{preseed: preseed, result: result} = MentalModelSearchingLLM.state()

    assert %{"query" => "new york city", "count" => 1, "mental_models" => [nyc]} = result
    assert nyc["id"] == "mm-nyc"
    assert nyc["name"] == "NYC guide"
    assert nyc["content"] == "nyc"
    assert nyc["relevance"] == 1.0
    assert nyc["is_stale"] == true
    assert nyc["staleness_reason"] == "never refreshed"

    # The opening context carried the relevant model (Hindsight searches models first).
    assert preseed =~ "PRE-RETRIEVED MENTAL MODELS"
    assert preseed =~ "mm-nyc"

    # Embeddings were materialised lazily under the bank's profile.
    assert {:ok, %{rows: [[2]]}} =
             Ecto.Adapters.SQL.query(
               Foresight.Repo,
               "SELECT COUNT(*) FROM mental_model_embeddings WHERE bank_id = $1",
               ["mm-bank"]
             )

    # The other model ranks first for its own cluster.
    MentalModelSearchingLLM.set_query("android")
    assert {:ok, _} = Foresight.reflect(ctx, %{"query" => "android"})

    assert %{"mental_models" => [%{"id" => "mm-android", "relevance" => 1.0}]} =
             MentalModelSearchingLLM.state().result
  end

  test "mental-model staleness follows the model's tag scope and last refresh" do
    put_engine(FakeToolCallingLLM, Foresight.TestSupport.SemanticEmbedder)
    ctx = %Context{tenant_id: "mm-tenant", mode: :mode_a, bank: "mm-stale-bank"}
    assert {:ok, _} = Foresight.put_bank(ctx, "mm-stale-bank", %{"name" => "MM stale"})

    just_now = DateTime.utc_now() |> DateTime.to_iso8601()

    global =
      insert_mental_model!(
        "mm-global",
        "Global",
        "everything",
        just_now,
        [],
        %{},
        "mm-stale-bank"
      )

    scoped =
      insert_mental_model!(
        "mm-scoped",
        "Scoped",
        "topic x only",
        just_now,
        ["topic:x"],
        %{"tags_match" => "any_strict"},
        "mm-stale-bank"
      )

    alias Foresight.Reflect.MentalModels

    assert {false, nil} = MentalModels.stale?(Foresight.Repo, "mm-stale-bank", global, [])
    assert {false, nil} = MentalModels.stale?(Foresight.Repo, "mm-stale-bank", scoped, [])

    # An untagged memory: the global model is stale, the strictly scoped one is not.
    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [%{"content" => "untagged news", "context" => "chat"}]
             })

    assert {true, "new in-scope memories ingested since last refresh"} =
             MentalModels.stale?(Foresight.Repo, "mm-stale-bank", global, [])

    assert {false, nil} = MentalModels.stale?(Foresight.Repo, "mm-stale-bank", scoped, [])

    # A memory carrying the model's tag makes it stale too.
    assert {:ok, _} =
             Foresight.retain(ctx, %{
               "async" => false,
               "items" => [
                 %{"content" => "topic x update", "context" => "chat", "tags" => ["topic:x"]}
               ]
             })

    assert {true, _} = MentalModels.stale?(Foresight.Repo, "mm-stale-bank", scoped, [])

    # get_mental_model reports the computed verdict, not the stored flag.
    assert {:ok, %{"is_stale" => true, "staleness_reason" => reason}} =
             Foresight.get_mental_model(ctx, "mm-stale-bank", "mm-scoped", %{})

    assert reason =~ "new in-scope memories"
  end

  defp insert_mental_model!(
         id,
         name,
         content,
         last_refreshed_at,
         tags \\ [],
         trigger \\ %{},
         bank \\ "mm-bank"
       ) do
    %Foresight.Schemas.Document{}
    |> Foresight.Schemas.Document.changeset(%{
      bank_id: bank,
      external_id: id,
      title: name,
      original_text: content,
      tags: tags,
      metadata: %{
        "document_type" => "mental_model",
        "source_query" => content,
        "trigger" => trigger,
        "last_refreshed_at" => last_refreshed_at,
        "is_stale" => is_nil(last_refreshed_at)
      }
    })
    |> Foresight.Repo.insert!()
  end

  test "grounding gate: an ungrounded answer re-enters the loop and is corrected" do
    ctx = %Context{tenant_id: "d4-tenant", mode: :mode_a, bank: "d4-bank"}
    put_engine(ReentryLLM)
    Application.put_env(:foresight, :entailment_verifier, ReentryGroundingVerifier)
    on_exit(fn -> Application.delete_env(:foresight, :entailment_verifier) end)

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [%{"content" => "the sky is blue", "context" => "chat", "type" => "world"}]
      })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what colour is the sky?"})

    # The gate rejected the first (ungrounded) answer and the loop re-entered, so the
    # accepted answer is the corrected, grounded one — with the gate recorded as passed.
    assert result["text"] == ReentryLLM.grounded()
    assert result["trace"]["entailment"]["passed"] == true
  end

  test "grounding gate control: default (Noop) verifier lets the ungrounded answer through unchanged" do
    ctx = %Context{tenant_id: "d4-off-tenant", mode: :mode_a, bank: "d4-off-bank"}
    put_engine(ReentryLLM)
    # No :entailment_verifier configured → gate off → no re-entry, no correction.

    {:ok, _} =
      Foresight.retain(ctx, %{
        "async" => false,
        "items" => [%{"content" => "the sky is blue", "context" => "chat", "type" => "world"}]
      })

    assert {:ok, result} = Foresight.reflect(ctx, %{"query" => "what colour is the sky?"})

    assert result["text"] == ReentryLLM.ungrounded()
    refute Map.has_key?(result["trace"], "entailment")
  end

  defp vector_field_name(384), do: :embedding_384
  defp vector_field_name(1024), do: :embedding_1024

  defp put_engine(llm, embedder \\ Foresight.TestSupport.FakeEmbedder) do
    Application.put_env(:foresight, :engine,
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: embedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: llm,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
