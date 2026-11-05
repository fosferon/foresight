defmodule Foresight.Fitness.CorpusPurityTest do
  use ExUnit.Case, async: true

  alias Foresight.Fitness.CorpusPurity

  test "the guard actually scans real files (non-vacuous)" do
    files = CorpusPurity.scanned_files()

    # A guard that resolves its root wrongly would scan zero files and pass on emptiness.
    refute files == []
    assert Enum.any?(files, &String.ends_with?(&1, "lib/foresight/storage/ecto.ex"))
    assert Enum.any?(files, &String.ends_with?(&1, "test/support/fake_storage.ex"))
  end

  test "recall/reflect code paths (incl. the FakeStorage double) are free of corpus literals" do
    assert CorpusPurity.violations() == []
  end

  test "planted corpus literals are detected" do
    violations =
      CorpusPurity.violations_for_sources([
        {"lib/foresight/storage/example.ex", ~S|defmodule Example do
           def gate?(content), do: String.contains?(content, "industrial-strength") and "project:helios-diary"
         end|}
      ])

    assert [%{file: "lib/foresight/storage/example.ex", literals: literals}] = violations
    assert "industrial-strength" in literals
    assert "project:helios-diary" in literals
  end

  test "catches separator and string-concatenation evasions" do
    for source <- [
          ~S|def x, do: "helios" <> "-diary"|,
          ~S|def x, do: "HELIOS_DIARY"|,
          ~S|def x, do: "industrial" <> "-strength"|,
          ~S|def x, do: "python  hindsight"|
        ] do
      violations = CorpusPurity.violations_for_sources([{"lib/foresight/x.ex", source}])
      assert [%{}] = violations, "expected #{source} to be flagged"
    end
  end

  test "generic revision vocabulary is not flagged" do
    violations =
      CorpusPurity.violations_for_sources([
        {"lib/foresight/storage/example.ex", ~S|defmodule Example do
           def factor(tags) do
             cond do
               "status:superseded" in tags -> 0.0
               "status:corrected" in tags -> 1.0
               true -> 0.5
             end
           end
         end|}
      ])

    assert violations == []
  end
end
