defmodule Foresight.Webhooks.HTTPClient do
  @moduledoc false

  @callback post(String.t(), map(), keyword()) ::
              {:ok, %{status: pos_integer(), body: binary()}}
              | {:error, term()}
end
