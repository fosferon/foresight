defmodule Foresight.Budget do
  @moduledoc false

  alias Foresight.Tokenizers.Cl100kBase

  @spec count_tokens(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_tokens(text, opts \\ []) when is_binary(text) do
    Cl100kBase.count(text, opts)
  end
end
