defmodule Foresight.Evals.ProfessionalLaneTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.Dataset
  alias Foresight.Evals.ProfessionalLane

  @data_path Path.expand("../../../priv/evals/data/professional_lane.json", __DIR__)
  @categories ~w(
    architecture-boundary
    incident-diagnosis
    supersession
    multi-hop-dependency
    operational-constraint
    strategic-decision
  )
  @forbidden_status_markers [
    "current",
    "deprecated",
    "deferred",
    "not-adopted",
    "supersession",
    "distractor",
    "adopted decision",
    "rejected proposal"
  ]
  @stop_words MapSet.new(~w(
                  about after again against also and any are because been before being between both
                  but can could did does each for from had has have how into its may must not now
                  one only other our should than that the their them then there these they this those
                  through under very was were what when where which while who why will with would
                ))

  setup_all do
    source = File.read!(@data_path)

    {:ok,
     source: source, raw: Jason.decode!(source), instances: ProfessionalLane.load!(@data_path)}
  end

  test "loads 30 datasets over one representative 78-memory corpus", %{instances: instances} do
    assert length(instances) == 30
    assert Enum.all?(instances, &match?(%Dataset{}, &1))
    assert Enum.all?(instances, &(length(&1.memories) == 78))
    assert Enum.all?(instances, &(&1.reference_answer not in [nil, ""]))

    [first | rest] = instances
    assert Enum.all?(rest, &(&1.memories === first.memories))
  end

  test "balances the six professional categories at exactly five queries each", %{
    instances: instances
  } do
    counts = Enum.frequencies_by(instances, & &1.question_type)

    assert Map.keys(counts) |> Enum.sort() == Enum.sort(@categories)
    assert Enum.all?(@categories, &(counts[&1] == 5))
  end

  test "uses stable unique query and memory ids", %{instances: instances} do
    query_ids = Enum.map(instances, & &1.id)
    memory_ids = instances |> hd() |> Map.fetch!(:memories) |> Enum.map(& &1["id"])

    assert length(Enum.uniq(query_ids)) == 30
    assert length(Enum.uniq(memory_ids)) == 78

    assert Enum.all?(
             query_ids,
             &Regex.match?(
               ~r/^professional-(architecture-boundary|incident-diagnosis|supersession|multi-hop-dependency|operational-constraint|strategic-decision)-0[1-5]$/,
               &1
             )
           )

    assert Enum.all?(memory_ids, &Regex.match?(~r/^(arch|inc|sup|dep|ops|str)-\d{3}$/, &1))

    for memory <- hd(instances).memories do
      assert memory["metadata"]["eval_id"] == memory["id"]
    end
  end

  test "all graded relevance references exist and every query has ideal evidence", %{
    instances: instances
  } do
    memory_ids =
      instances
      |> hd()
      |> Map.fetch!(:memories)
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    for instance <- instances do
      assert map_size(instance.relevance) > 0
      assert Enum.all?(Map.keys(instance.relevance), &MapSet.member?(memory_ids, &1))
      assert Enum.all?(Map.values(instance.relevance), &(&1 in 0..3))
      assert Enum.any?(instance.relevance, fn {_id, grade} -> grade == 3 end)
      assert Enum.count(instance.relevance, fn {_id, grade} -> grade == 0 end) in 3..5

      if instance.question_type == "multi-hop-dependency" do
        assert Enum.count(instance.relevance, fn {_id, grade} -> grade == 3 end) >= 2
      end
    end
  end

  test "defines query-specific hard negatives without leaking answer status into memories", %{
    raw: raw
  } do
    memory_ids = raw["memories"] |> Enum.map(& &1["id"]) |> MapSet.new()

    for memory <- raw["memories"] do
      tags = Enum.map(memory["tags"], &String.downcase/1)
      context = String.downcase(memory["context"])
      metadata = Enum.join([context | tags], " ")

      assert Enum.all?(
               @forbidden_status_markers,
               &(not String.contains?(metadata, &1))
             )
    end

    for query <- raw["queries"] do
      negatives = query["hard_negatives"]
      positive_ids = Map.keys(query["relevance"]) |> MapSet.new()

      assert length(negatives) in 3..5
      assert length(Enum.uniq(negatives)) == length(negatives)
      assert Enum.all?(negatives, &MapSet.member?(memory_ids, &1))
      assert Enum.all?(negatives, &(not MapSet.member?(positive_ids, &1)))
    end
  end

  test "queries are indirect and do not copy gold memory phrasing", %{raw: raw} do
    memories = Map.new(raw["memories"], &{&1["id"], &1["content"]})

    for query <- raw["queries"] do
      refute query["query"] =~ "schema-per-tenant"
      refute query["query"] =~ "busy_timeout"
      refute query["query"] =~ "per message and per recipient"
      refute query["query"] =~ "native OTP release"

      for {id, _grade} <- query["relevance"] do
        assert containment(query["query"], memories[id]) < 0.55
      end
    end
  end

  test "hard negatives retain topical vocabulary without copying the answer", %{raw: raw} do
    memories = Map.new(raw["memories"], &{&1["id"], &1["content"]})

    for query <- raw["queries"], id <- query["hard_negatives"] do
      # Hard distractors may share domain terms, but should not restate either the
      # information need or enough of the reference answer to supply it directly.
      assert containment(query["query"], memories[id]) < 0.35
      assert containment(query["reference_answer"], memories[id]) < 0.35
    end
  end

  test "hard negatives have meaningful topical overlap with query or evidence", %{raw: raw} do
    memories = Map.new(raw["memories"], &{&1["id"], &1["content"]})

    for query <- raw["queries"], id <- query["hard_negatives"] do
      query_terms = stemmed_terms(query["query"])

      evidence_terms =
        query["relevance"]
        |> Enum.flat_map(fn {eid, _grade} -> stemmed_terms(memories[eid]) end)
        |> MapSet.new()

      combined = MapSet.union(query_terms, evidence_terms)
      neg_terms = stemmed_terms(memories[id])

      overlap = MapSet.intersection(neg_terms, combined) |> MapSet.size()

      # A hard negative must share at least one stemmed content term with the
      # query or its positive evidence, ensuring genuine topical relatedness
      # rather than trivially-unrelated cross-domain noise.
      assert overlap >= 1,
             "hard negative #{id} for #{query["id"]} shares #{overlap} stemmed term(s) " <>
               "with query/evidence — expected at least 1"
    end
  end

  test "multi-hop answers synthesize multiple artifacts", %{raw: raw} do
    memories = Map.new(raw["memories"], &{&1["id"], &1})

    for query <- Enum.filter(raw["queries"], &(&1["category"] == "multi-hop-dependency")) do
      ideal_ids =
        for {id, grade} <- query["relevance"], grade == 3, do: id

      assert length(ideal_ids) >= 2

      assert ideal_ids
             |> Enum.map(&memories[&1]["context"])
             |> Enum.uniq()
             |> length() >= 2

      assert Enum.all?(
               ideal_ids,
               &(containment(query["reference_answer"], memories[&1]["content"]) < 0.72)
             )
    end
  end

  test "encodes the audited professional scenario topology", %{raw: raw} do
    queries = Map.new(raw["queries"], &{&1["id"], &1})
    memories = Map.new(raw["memories"], &{&1["id"], &1})

    supersession = queries["professional-supersession-01"]
    assert supersession["relevance"]["sup-011"] == 2
    refute "sup-011" in supersession["hard_negatives"]

    recovery = queries["professional-operational-constraint-02"]
    assert recovery["relevance"]["ops-014"] == 2

    multi_hop = queries["professional-multi-hop-dependency-04"]
    assert multi_hop["relevance"]["ops-014"] == 3
    assert multi_hop["relevance"]["ops-016"] == 3
    refute memories["ops-014"]["context"] == memories["ops-016"]["context"]
    refute memories["ops-014"]["content"] =~ "transactional outbox"
    refute memories["ops-016"]["content"] =~ "object archive"

    operations = queries["professional-operational-constraint-03"]
    strategy = queries["professional-strategic-decision-03"]

    assert operations["relevance"]["ops-013"] == 3
    assert memories["ops-013"]["content"] =~ "BEAM"
    refute "ops-013" in Map.keys(strategy["relevance"])

    refute Enum.any?(["str-003", "str-008", "str-011"], fn id ->
             Map.has_key?(operations["relevance"], id)
           end)
  end

  test "supersession prompts present conflicts without declaring authority", %{raw: raw} do
    audited_ids =
      ~w(
        professional-supersession-01
        professional-supersession-02
        professional-supersession-03
        professional-supersession-04
        professional-supersession-05
      )

    queries = Map.new(raw["queries"], &{&1["id"], &1["query"]})

    for id <- audited_ids do
      refute Regex.match?(
               ~r/\b(old|current|authoritative|supersed\w*|governs|wins|corrected|rejected)\b/i,
               queries[id]
             )
    end
  end

  test "covers representative professional systems vocabulary", %{raw: raw} do
    corpus =
      Enum.map_join(raw["memories"], "\n", & &1["content"]) <>
        "\n" <> Enum.map_join(raw["queries"], "\n", & &1["query"])

    for term <- [
          "PostgreSQL",
          "GenServer",
          "ETS",
          "CNAME",
          "PHP-FPM",
          "WooCommerce",
          "WAL",
          "busy_timeout",
          "OTP",
          "MessageBus",
          "ConversationEngine"
        ] do
      assert corpus =~ term
    end
  end

  test "source contains no common credential, address, or hostname patterns", %{source: source} do
    refute Regex.match?(~r/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, source)
    refute Regex.match?(~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/, source)
    refute Regex.match?(~r/https?:\/\/\S+/, source)
    refute Regex.match?(~r/AKIA[0-9A-Z]{16}/, source)
    refute source =~ "BEGIN PRIVATE KEY"

    refute source =~ "CommBus"
  end

  defp containment(left, right) do
    left_terms = terms(left)
    right_terms = terms(right)

    MapSet.intersection(left_terms, right_terms)
    |> MapSet.size()
    |> Kernel./(max(MapSet.size(left_terms), 1))
  end

  defp terms(text) do
    ~r/[a-z0-9_]+/
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.reject(&(String.length(&1) < 4 or MapSet.member?(@stop_words, &1)))
    |> MapSet.new()
  end

  defp stemmed_terms(text) do
    ~r/[a-z0-9_]+/
    |> Regex.scan(String.downcase(text))
    |> List.flatten()
    |> Enum.reject(&(String.length(&1) < 4 or MapSet.member?(@stop_words, &1)))
    |> Enum.map(&String.slice(&1, 0, 5))
    |> MapSet.new()
  end
end
