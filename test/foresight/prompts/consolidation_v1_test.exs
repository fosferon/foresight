defmodule Foresight.Prompts.Consolidation.V1Test do
  @moduledoc """
  Unit coverage for the consolidation prompt module:
  the default observations mission and the serialized-observation shape
  that feeds the LLM merge context.
  """
  use ExUnit.Case, async: true

  alias Foresight.Prompts.Consolidation.V1, as: ConsolidationPrompt

  describe "default mission" do
    test "the default mission mirrors Hindsight's _DEFAULT_MISSION" do
      [%{role: :system, content: system} | _] =
        ConsolidationPrompt.messages(nil, "(none)", "[]")

      # Hindsight prompts.py:4 — the concrete/specific directive Foresight had dropped.
      assert system =~ "Prefer specifics over abstractions"
      assert system =~ "never generalise"
    end

    test "an explicit bank mission overrides the default" do
      [%{role: :system, content: system} | _] =
        ConsolidationPrompt.messages("Track only cats", "(none)", "[]")

      assert system =~ "Track only cats"
      refute system =~ "never generalise"
    end
  end
end
