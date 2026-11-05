defmodule Foresight.Reflect.DispositionTest do
  @moduledoc """
  Render a bank's stored disposition traits into behavioural prose
  for the reflect prompt — a faithful port of Hindsight's `think_utils.build_disposition_description`
  + `describe_trait_level`. Activates the currently-inert disposition_skepticism/literalism/
  empathy fields.

  Deviation from Hindsight (documented): an ABSENT disposition renders "" (no guidance),
  rather than Hindsight's always-present 3/3/3 default — so banks that set no disposition
  keep a clean prompt. Any trait present → all three render (missing default to moderate).
  """
  use ExUnit.Case, async: true

  alias Foresight.Reflect.Disposition

  test "an empty / nil disposition renders nothing" do
    assert Disposition.describe(%{}) == ""
    assert Disposition.describe(nil) == ""
  end

  test "a full disposition renders each trait's level name + description" do
    desc = Disposition.describe(%{"skepticism" => 5, "literalism" => 1, "empathy" => 3})
    assert desc =~ "Your disposition traits:"
    assert desc =~ "Skepticism (very high): You are highly skeptical"
    assert desc =~ "Literalism (very low): You interpret information very flexibly"
    assert desc =~ "Empathy (moderate): You balance factual analysis"
  end

  test "a partial disposition still renders all three; missing traits default to moderate" do
    desc = Disposition.describe(%{"skepticism" => 4})
    assert desc =~ "Skepticism (high): You are somewhat skeptical"
    assert desc =~ "Literalism (moderate):"
    assert desc =~ "Empathy (moderate):"
  end

  test "tolerates atom keys" do
    assert Disposition.describe(%{skepticism: 2}) =~ "Skepticism (low): You tend to trust"
  end

  test "tolerates the disposition_-prefixed field keys" do
    desc = Disposition.describe(%{"disposition_literalism" => 5})
    assert desc =~ "Literalism (very high): You interpret information very literally"
  end

  test "tolerates stringified integer values" do
    assert Disposition.describe(%{"empathy" => "5"}) =~
             "Empathy (very high): You strongly consider"
  end

  test "out-of-range levels fall back to moderate (label and description)" do
    desc = Disposition.describe(%{"skepticism" => 9})
    assert desc =~ "Skepticism (moderate): You have a balanced approach"
  end

  test "the agentic system prompt includes the disposition prose when the bank sets one" do
    prompt =
      Foresight.Prompts.Reflect.Agent.V1.system_prompt(
        bank_profile: %{"disposition" => %{"skepticism" => 5}}
      )

    assert prompt =~ "Your disposition traits:"
    assert prompt =~ "You are highly skeptical"
  end

  test "the agentic system prompt omits disposition when the bank sets none" do
    prompt = Foresight.Prompts.Reflect.Agent.V1.system_prompt(bank_profile: %{})
    refute prompt =~ "disposition traits"
  end
end
