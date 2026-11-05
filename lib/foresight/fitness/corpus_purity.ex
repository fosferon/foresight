defmodule Foresight.Fitness.CorpusPurity do
  @moduledoc """
  Fitness check: recall/reflect logic must not hardcode eval-corpus or project literals.

  Foresight's ranking quality was once inflated by branching on specific corpus phrases
  (`"helios-diary"`, `"industrial-strength"`, `"next-week"`, …) so that the eval's own
  documents scored highly — a metric gamed from the inside. That was excised, from
  both the production storage AND the FakeStorage test double that "proves" recall
  behaviour without a database. This check fails closed if any of those literals reappear
  in either place, so the contamination cannot silently regrow into a green build.

  Generic revision vocabulary (`status:latest`, `superseded`, `corrected`) is allowed —
  the ban targets domain proper-nouns and corpus content phrases only.

  The check is non-vacuous by construction: `scanned_files/0` must be non-empty, and the
  accompanying test asserts it. (An earlier version resolved its repo root incorrectly and
  silently scanned zero files — passing on emptiness. Never again.)
  """

  @repo_root Path.expand("../../..", __DIR__)

  @scanned_globs [
    "lib/foresight/storage/ecto.ex",
    "lib/foresight/recall/**/*.ex",
    "lib/foresight/prompts/reflect/**/*.ex",
    "test/support/fake_storage.ex"
  ]

  # Case-insensitive substrings that only ever appear to fit the eval corpus. Each is a
  # project name, place, or corpus content phrase with no place in generic ranking logic.
  @banned_literals [
    "helios-diary",
    "helios_diary",
    "project:helios-diary",
    "industrial-strength",
    "next-week",
    "oxford",
    "python hindsight",
    "cutover gate",
    "real gate",
    "governing gate"
  ]

  @type violation :: %{file: String.t(), literals: [String.t()]}

  @spec banned_literals() :: [String.t()]
  def banned_literals, do: @banned_literals

  @spec scanned_files() :: [String.t()]
  def scanned_files do
    @scanned_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(@repo_root, glob)) end)
    |> Enum.uniq()
  end

  @spec violations() :: [violation()]
  def violations do
    scanned_files()
    |> Enum.map(&source_violation(&1, File.read!(&1)))
    |> Enum.reject(&is_nil/1)
  end

  @spec violations_for_sources([{String.t(), String.t()}]) :: [violation()]
  def violations_for_sources(sources) do
    sources
    |> Enum.map(fn {file, source} -> source_violation(file, source) end)
    |> Enum.reject(&is_nil/1)
  end

  defp source_violation(file, source) do
    # Match against a separator-stripped, lowercased form of the source so trivial evasions
    # collapse onto the same token: "helios-diary", "helios_diary", "HELIOS DIARY", and the
    # string-concatenation dodge `"helios" <> "-diary"` all normalise to "heliosdiary". The
    # banned literals are normalised the same way before comparison.
    normalized = normalize(source)

    literals =
      Enum.filter(@banned_literals, fn literal ->
        String.contains?(normalized, normalize(literal))
      end)

    if literals == [], do: nil, else: %{file: relative(file), literals: literals}
  end

  defp normalize(string) do
    string |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp relative(file) do
    case Path.relative_to(file, @repo_root) do
      ^file -> file
      relative -> relative
    end
  end
end
