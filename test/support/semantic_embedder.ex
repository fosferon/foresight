defmodule Foresight.TestSupport.SemanticEmbedder do
  @moduledoc """
  A DISCRIMINATING test embedder for semantic entity recall.

  Unlike FakeEmbedder (all-ones → cosine 1.0 between everything, useless for
  similarity), this maps each string to a one-hot vector keyed by a semantic
  cluster, so names in the same cluster have cosine 1.0 and names in different
  clusters have cosine 0.0. Synonyms ("NYC" / "New York City") share a cluster;
  unrelated names do not.
  """
  @behaviour Foresight.Embedder

  @dim 384

  # Synonym clusters share an index; everything else hashes to its own.
  @clusters %{
    "nyc" => 0,
    "new york city" => 0,
    "new york" => 0,
    "android" => 1,
    "google" => 2,
    "google inc" => 2,
    "goggle" => 2,
    "spanish course" => 3,
    "pottery course" => 4,
    "evening classes" => 5,
    "user" => 6
  }

  @impl true
  def dimension(_opts), do: {:ok, @dim}

  @impl true
  def embed("", _opts), do: {:ok, List.duplicate(0.0, @dim)}

  def embed(text, _opts) do
    idx = cluster_index(String.downcase(String.trim(text)))
    vec = for i <- 0..(@dim - 1), do: if(i == idx, do: 1.0, else: 0.0)
    {:ok, vec}
  end

  # Known synonym clusters keep their small index; unknowns hash into [20, 319]
  # so they never collide with a defined cluster (0..6) and stay within @dim.
  defp cluster_index(name) do
    case Map.fetch(@clusters, name) do
      {:ok, idx} -> idx
      :error -> 20 + :erlang.phash2(name, 300)
    end
  end
end
