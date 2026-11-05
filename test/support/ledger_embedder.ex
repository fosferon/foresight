defmodule Foresight.TestSupport.LedgerEmbedder do
  @moduledoc """
  The fake embedder with the remote embedder's accounting: every call writes an
  embedding entry to the open `Foresight.Usage` ledger, so tests can prove usage
  flows through retain and recall results without a network.
  """

  @behaviour Foresight.Embedder

  alias Foresight.TestSupport.FakeEmbedder

  @impl true
  def dimension(opts), do: FakeEmbedder.dimension(opts)

  @impl true
  def embed(text, opts) do
    record(1)
    FakeEmbedder.embed(text, opts)
  end

  @impl true
  def embed_many(texts, opts) do
    record(length(texts))

    # FakeEmbedder.embed/2 cannot fail, so there is no error path to propagate.
    {:ok,
     Enum.map(texts, fn text ->
       {:ok, vector} = FakeEmbedder.embed(text, opts)
       vector
     end)}
  end

  defp record(units) do
    Foresight.Usage.record(%{
      "kind" => "embedding",
      "provider" => "ledger-fake",
      "model" => "fake-embedder",
      "input_tokens" => 3 * units,
      "output_tokens" => 0,
      "total_tokens" => 3 * units,
      "units" => units,
      "status" => "ok"
    })
  end
end
