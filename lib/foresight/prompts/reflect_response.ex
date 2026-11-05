defmodule Foresight.Prompts.ReflectResponse do
  @moduledoc false

  @enforce_keys [:text]
  defstruct [:text, :directive_compliance, :memory_ids, :mental_model_ids, :observation_ids]

  @type t :: %__MODULE__{
          text: String.t(),
          directive_compliance: map() | nil,
          memory_ids: list(String.t()) | nil,
          mental_model_ids: list(String.t()) | nil,
          observation_ids: list(String.t()) | nil
        }
end
