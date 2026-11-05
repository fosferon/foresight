defmodule Foresight.Reranker do
  @moduledoc false

  @callback rerank(String.t(), [map()], keyword()) :: {:ok, [map()]} | {:error, term()}
end
