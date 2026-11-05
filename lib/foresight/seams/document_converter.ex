defmodule Foresight.DocumentConverter do
  @moduledoc false

  @type file_input :: %{required(String.t()) => term()}

  @type conversion_result :: %{
          required(:text) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:metadata) => map(),
          optional(:content_type) => String.t() | nil
        }

  @callback convert(file_input(), keyword()) :: {:ok, conversion_result()} | {:error, term()}
end
