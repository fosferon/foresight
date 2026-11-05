defmodule Foresight.Context do
  @moduledoc """
  Execution context for the public API.

  Every public function in `Foresight` takes a `t:t/0` as its first argument:
  the tenant, the tenancy `mode` (`:mode_a`, `:mode_b`, or `:mode_c`), the
  `bank`, and the values the storage and embedding layers resolve from them
  (`role_name`, `prefix`, `embedding_dim`).
  """

  @enforce_keys [:tenant_id, :mode, :bank]
  defstruct [:tenant_id, :mode, :bank, :role_name, :prefix, :embedding_dim]

  @type mode :: :mode_a | :mode_b | :mode_c

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          mode: mode(),
          bank: String.t(),
          role_name: String.t() | nil,
          prefix: String.t() | nil,
          embedding_dim: pos_integer() | nil
        }
end
