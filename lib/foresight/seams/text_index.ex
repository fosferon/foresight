defmodule Foresight.TextIndex do
  @moduledoc false

  @callback search(term(), keyword()) :: {:ok, list(term())} | {:error, term()}
end
