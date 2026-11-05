defmodule Foresight.Evals.ProfessionalLane do
  @moduledoc """
  Loader for the sanitized professional knowledge-work evaluation lane.

  The source file stores one shared memory corpus and a set of queries. Each query is
  expanded into a `Foresight.Evals.Dataset` over that common corpus.
  """

  alias Foresight.Evals.Dataset

  @spec load!(String.t()) :: [Dataset.t()]
  def load!(path) do
    raw =
      path
      |> File.read!()
      |> Jason.decode!()

    memories =
      raw
      |> Map.fetch!("memories")
      |> Dataset.label_memories()

    raw
    |> Map.fetch!("queries")
    |> Enum.map(&to_dataset(&1, memories))
  end

  defp to_dataset(query, memories) do
    relevance =
      query
      |> Map.get("hard_negatives", [])
      |> Map.new(&{&1, 0})
      |> Map.merge(Map.fetch!(query, "relevance"))

    %Dataset{
      id: Map.fetch!(query, "id"),
      query: Map.fetch!(query, "query"),
      query_timestamp: query["query_timestamp"],
      question_type: Map.fetch!(query, "category"),
      memories: memories,
      relevance: relevance,
      reference_answer: query["reference_answer"]
    }
  end
end
