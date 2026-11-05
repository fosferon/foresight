defmodule Foresight.DocumentConverters.Noop do
  @moduledoc false

  @behaviour Foresight.DocumentConverter

  @impl true
  def convert(_file_input, _opts), do: Foresight.not_implemented("document_converter.convert")
end
