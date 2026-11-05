defmodule Foresight.Embedder do
  @moduledoc false

  @callback embed(String.t(), keyword()) :: {:ok, list(number())} | {:error, term()}
  @callback embed_many([String.t()], keyword()) :: {:ok, [list(number())]} | {:error, term()}
  @callback dimension(keyword()) :: {:ok, pos_integer()} | {:error, term()}

  @optional_callbacks embed_many: 2
end
