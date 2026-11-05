defmodule Foresight.Fitness.IsolationCoverage do
  @moduledoc false

  # Audit finding: the Mode C isolation probes are the continuous proof that the cross-tenant
  # escape stays closed. They spent their first months tagged :tier2, which the
  # default lane excludes — so the guarantee was asserted but never actually verified by
  # `mix ci`. A silently-skipped isolation probe is worse than no probe, because it reads
  # as coverage.
  #
  # This check fails the build if an isolation test carries a tag the default lane skips,
  # or if the isolation suite disappears entirely. It is deliberately a fitness function
  # rather than a convention: a tag is one line to add back under time pressure.

  @engine_root Path.expand("../../..", __DIR__)
  @isolation_dir Path.join(@engine_root, "test/foresight/isolation")

  # Mirrors the exclusions applied in test/test_helper.exs.
  @excluded_tags ~w(tier2 nightly ml)

  @type violation :: %{file: String.t(), reason: String.t()}

  @spec violations() :: [violation()]
  def violations do
    violations_for_dir(@isolation_dir)
  end

  @spec violations_for_dir(String.t()) :: [violation()]
  def violations_for_dir(dir) do
    case test_files(dir) do
      [] ->
        [
          %{
            file: dir,
            reason: "no isolation probe tests found; the Mode C guarantee is unverified"
          }
        ]

      files ->
        Enum.flat_map(files, fn file -> violations_for_source(file, File.read!(file)) end)
    end
  end

  @spec violations_for_source(String.t(), String.t()) :: [violation()]
  def violations_for_source(file, source) do
    Enum.flat_map(@excluded_tags, fn tag ->
      # Matches every form ExUnit accepts, not just the bare atom: @moduletag :tier2,
      # @moduletag [:tier2, :nightly], @moduletag tier2: true, @moduletag [tier2: true].
      # The narrower regex this replaces would have let any of the latter three silently
      # re-exclude the isolation suite (an audit finding).
      pattern = ~r/^\s*@(?:module)?tag\s+.*(?::#{tag}\b|\b#{tag}:)/m

      if Regex.match?(pattern, source) do
        [
          %{
            file: file,
            reason:
              "tagged :#{tag}, which the default test lane excludes — " <>
                "the isolation probe would be skipped by `mix ci`"
          }
        ]
      else
        []
      end
    end)
  end

  defp test_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, "_test.exs"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end
end
