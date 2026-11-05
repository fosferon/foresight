defmodule Foresight.Prompts.ReflectPlanResponse do
  @moduledoc false

  @enforce_keys [:focus_query, :needs_consolidation, :answer_ready]
  defstruct [:focus_query, :needs_consolidation, :answer_ready, :reason, :refinement_intent]

  @type t :: %__MODULE__{
          focus_query: String.t(),
          needs_consolidation: boolean(),
          answer_ready: boolean(),
          reason: String.t() | nil,
          refinement_intent: String.t() | nil
        }
end
