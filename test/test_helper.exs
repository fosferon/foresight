# Kill orphaned test Postgres instances and remove stale temp dirs from
# previous crashed runs before any test module starts.
Foresight.TestSupport.PostgresHarness.cleanup_stale!()

include_tags =
  System.get_env("FORESIGHT_TEST_INCLUDE_TAGS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> MapSet.new()

exclude_tags =
  [:tier2, :nightly, :ml, :eval]
  |> Enum.reject(&MapSet.member?(include_tags, Atom.to_string(&1)))
  |> Enum.map(&{&1, true})

# Scrivener RTF decoding shells out to macOS `textutil`; elsewhere those tests are
# excluded rather than failed.
exclude_tags =
  if System.find_executable("textutil"),
    do: exclude_tags,
    else: [{:textutil, true} | exclude_tags]

ExUnit.start(exclude: exclude_tags)
