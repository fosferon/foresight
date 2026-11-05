defmodule Foresight.Ingestion.ScrivenerTest do
  use ExUnit.Case, async: false

  alias Foresight.DocumentConverters.Scrivener, as: ScrivenerConverter
  alias Foresight.Ingestion.Scrivener

  @fixture_path Path.expand("../../fixtures/scrivener/tiny.scriv", __DIR__)
  @real_path "/path/to/a-real-project.scriv"

  @tag :textutil
  test "converts a Scrivener binder into ordered Greek scene chunks" do
    assert {:ok, conversion} =
             ScrivenerConverter.convert(
               %{
                 "path" => @fixture_path,
                 "filename" => "tiny.scriv",
                 "content_type" => "application/vnd.literatureandlatte.scrivener"
               },
               []
             )

    assert conversion.title == "tiny.scriv"
    assert conversion.metadata["source"] == "scrivener"
    assert conversion.metadata["scene_count"] == 2

    assert [
             %{
               "text" => "Καλημέρα κόσμε.",
               "source" => "scrivener",
               "binder_path" => ["Κεφάλαιο Α"],
               "title" => "Σκηνή πρώτη",
               "synopsis" => "Περίληψη πρώτης σκηνής",
               "uuid" => "SCENE-1",
               "order_index" => 0,
               "sibling_index" => 0,
               "label_id" => "7",
               "keyword_ids" => ["3"]
             },
             %{
               "text" => "Δεύτερη σκηνή.",
               "binder_path" => ["Κεφάλαιο Β"],
               "title" => "Σκηνή δεύτερη",
               "uuid" => "SCENE-2",
               "order_index" => 1,
               "sibling_index" => 0
             }
           ] = conversion.chunks
  end

  # Runs only where a real bundle is present. @real_path is one author's machine,
  # so asserting File.dir? unconditionally made `mix ci` — the command the README
  # tells a new consumer to run — fail everywhere else. Skip rather than fail, and
  # let another machine point at its own bundle via the env var.
  @real_bundle System.get_env("FORESIGHT_SCRIVENER_BUNDLE", @real_path)

  @tag :skip_unless_real_bundle
  test "dry-runs the real Scrivener bundle without retaining anything" do
    if File.dir?(@real_bundle) do
      assert {:ok, report} = Scrivener.dry_run(@real_bundle)
      assert report.scene_count > 20
      assert report.sample_scene.uuid
      assert report.sample_scene.text =~ ~r/\p{Greek}/u

      IO.puts("""
      Scrivener dry run: #{report.scene_count} scenes
      Sample #{report.sample_scene.uuid}: #{String.slice(report.sample_scene.text, 0, 120)}
      """)
    else
      IO.puts("skipping real-bundle dry run: #{@real_bundle} not present")
    end
  end

  describe "hostile bundles" do
    # The UUID is an attacker-controlled attribute of a shareable file format.
    # Unvalidated it is a path-traversal read primitive, and even a miss leaks
    # existence via File.exists?. Reported as a BLOCKER by an audit.
    for hostile <- [
          "../../../../etc",
          "..",
          "SCENE-1/../../../..",
          "/etc",
          "a/b"
        ] do
      test "rejects a document UUID that escapes the bundle: #{inspect(hostile)}" do
        bundle = hostile_bundle(unquote(hostile))

        assert {:error, %Foresight.Error{reason: :invalid_request, detail: detail}} =
                 ScrivenerConverter.convert(
                   %{"path" => bundle, "filename" => "hostile.scriv"},
                   []
                 )

        assert detail.message =~ "unsafe document UUID"
      end
    end

    # The lexical guards cannot see these: Path.expand does not resolve symlinks,
    # so the containment check compares literal strings while the OS follows the
    # link. A .scriv travels as a zip/tarball, and archives carry symlinks.
    test "refuses a bundle whose Files/Data is a symlink pointing outside" do
      bundle = hostile_bundle("SCENE-1")
      outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(outside, "SCENE-1"))
      File.write!(Path.join([outside, "SCENE-1", "content.rtf"]), "leaked")
      on_exit(fn -> File.rm_rf(outside) end)

      File.rm_rf!(Path.join([bundle, "Files", "Data"]))
      File.ln_s!(outside, Path.join([bundle, "Files", "Data"]))

      assert {:error, %Foresight.Error{reason: :invalid_request, detail: detail}} =
               ScrivenerConverter.convert(
                 %{"path" => bundle, "filename" => "hostile.scriv"},
                 []
               )

      assert detail.message =~ "symlinked path component"
    end

    test "refuses a bundle whose content.rtf is itself a symlink" do
      bundle = hostile_bundle("SCENE-1")
      secret = Path.join(System.tmp_dir!(), "secret-#{System.unique_integer([:positive])}.rtf")
      File.write!(secret, "leaked")
      on_exit(fn -> File.rm_rf(secret) end)

      scene_dir = Path.join([bundle, "Files", "Data", "SCENE-1"])
      File.mkdir_p!(scene_dir)
      File.ln_s!(secret, Path.join(scene_dir, "content.rtf"))

      assert {:error, %Foresight.Error{reason: :invalid_request, detail: detail}} =
               ScrivenerConverter.convert(
                 %{"path" => bundle, "filename" => "hostile.scriv"},
                 []
               )

      assert detail.message =~ "symlinked path component"
    end

    # A size gate says nothing about a thing with no meaningful size: a FIFO
    # reports 0 bytes and blocks xmerl forever waiting for a writer.
    test "refuses a binder that is not a regular file" do
      dir = Path.join(System.tmp_dir!(), "fifo-#{System.unique_integer([:positive])}.scriv")
      File.mkdir_p!(Path.join([dir, "Files", "Data"]))
      on_exit(fn -> File.rm_rf(dir) end)

      {_, 0} = System.cmd("mkfifo", [Path.join(dir, "binder.scrivx")])

      assert {:error, %Foresight.Error{reason: :invalid_request, detail: detail}} =
               Scrivener.parse(dir)

      assert detail.message =~ "not a regular file"
      assert detail.type == :other
    end

    test "refuses an oversized binder before xmerl builds the tree" do
      assert {:error, %Foresight.Error{reason: :invalid_request, detail: detail}} =
               Scrivener.parse(@fixture_path, max_scrivx_bytes: 10)

      assert detail.message =~ "exceeds the maximum size"
      assert detail.max_bytes == 10
    end

    @tag :textutil
    test "refuses a manuscript with more scenes than the declared ceiling" do
      assert {:error, %Foresight.Error{reason: :invalid_request, detail: detail}} =
               Scrivener.parse(@fixture_path, max_scenes: 1)

      assert detail.message =~ "exceeds the maximum scene count"
      assert detail.scene_count == 2
    end

    @tag :textutil
    test "still accepts the identifier shapes real bundles use" do
      assert {:ok, conversion} =
               ScrivenerConverter.convert(
                 %{"path" => @fixture_path, "filename" => "tiny.scriv"},
                 []
               )

      assert Enum.map(conversion.chunks, & &1["uuid"]) == ["SCENE-1", "SCENE-2"]
    end

    defp hostile_bundle(uuid) do
      dir = Path.join(System.tmp_dir!(), "hostile-#{System.unique_integer([:positive])}.scriv")
      File.mkdir_p!(Path.join([dir, "Files", "Data"]))

      # Must mirror the real binder shape (DraftFolder titled Manuscript), or the
      # parser rejects the bundle for structure before it ever reaches the UUID —
      # which would make these tests pass for the wrong reason.
      File.write!(Path.join(dir, "hostile.scrivx"), """
      <?xml version="1.0" encoding="UTF-8"?>
      <ScrivenerProject Identifier="HOSTILE" Version="2.0">
        <Binder>
          <BinderItem UUID="DRAFT" Type="DraftFolder">
            <Title>Manuscript</Title>
            <Children>
              <BinderItem UUID="#{uuid}" Type="Text">
                <Title>hostile</Title>
              </BinderItem>
            </Children>
          </BinderItem>
        </Binder>
      </ScrivenerProject>
      """)

      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end
  end
end

defmodule Foresight.Ingestion.ScrivenerTier2Test do
  use ExUnit.Case, async: false

  alias Foresight.Context
  alias Foresight.Ingestion.Scrivener

  @moduletag :tier2
  @moduletag timeout: 120_000

  @fixture_path Path.expand("../../fixtures/scrivener/tiny.scriv", __DIR__)

  setup_all do
    start_supervised!(Foresight.TestSupport.FakeStorage)
    start_supervised!(Foresight.TestSupport.FakeAsyncQueue)
    :ok
  end

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    original_engine = Application.get_env(:foresight, :engine)

    Foresight.TestSupport.FakeStorage.reset!()
    Foresight.TestSupport.FakeAsyncQueue.reset!()

    Application.put_env(:foresight, :backend, Foresight.Backend.Store)

    Application.put_env(:foresight, :engine,
      storage: Foresight.TestSupport.FakeStorage,
      repo: Foresight.Repo,
      embedder: Foresight.TestSupport.FakeEmbedder,
      reranker: Foresight.TestSupport.FakeReranker,
      llm: Foresight.LLMs.Noop,
      queue: Foresight.TestSupport.FakeAsyncQueue,
      oban_name: Foresight.Oban,
      reranker_serving_name: Foresight.ML.RerankerServing
    )

    on_exit(fn ->
      restore(:backend, original_backend)
      restore(:engine, original_engine)
    end)

    :ok
  end

  test "ingests fixture scenes through the real retain path with shared document provenance" do
    ctx = %Context{tenant_id: "scrivener-tier2-tenant", mode: :mode_a, bank: "scrivener-tier2"}
    document_id = Scrivener.document_id(@fixture_path)

    assert {:ok, %{"operation_ids" => []}} = Scrivener.ingest(ctx, @fixture_path, async: false)

    {units, document} =
      Agent.get(Foresight.TestSupport.FakeStorage, fn state ->
        units =
          state.memory_units
          |> Enum.filter(&(&1["bank_id"] == ctx.bank and &1["document_ref"] == document_id))
          |> Enum.sort_by(& &1["source_location"]["order_index"])

        {units, Map.fetch!(state.documents, {ctx.bank, document_id})}
      end)

    assert Enum.map(units, & &1["content"]) == ["Καλημέρα κόσμε.", "Δεύτερη σκηνή."]
    assert Enum.map(units, & &1["document_ref"]) == [document_id, document_id]

    assert Enum.map(units, &get_in(&1, ["source_location", "source"])) == [
             "scrivener",
             "scrivener"
           ]

    assert Enum.map(units, &get_in(&1, ["source_location", "binder_path"])) == [
             ["Κεφάλαιο Α"],
             ["Κεφάλαιο Β"]
           ]

    assert Enum.map(units, &get_in(&1, ["source_location", "order_index"])) == [0, 1]

    assert document["title"] == "tiny.scriv"
    assert document["metadata"]["source"] == "scrivener"
    assert document["metadata"]["scrivener_path"] == @fixture_path
    refute Map.has_key?(document, "file_storage_key")
    assert document["original_text"] =~ "Καλημέρα κόσμε."
  end

  defp restore(key, nil), do: Application.delete_env(:foresight, key)
  defp restore(key, value), do: Application.put_env(:foresight, key, value)
end
