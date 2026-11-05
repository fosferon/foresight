defmodule Foresight.TenantResolver do
  @moduledoc false

  alias Foresight.Context

  @callback resolve(term(), keyword()) :: {:ok, Context.t()} | {:error, term()}
end
