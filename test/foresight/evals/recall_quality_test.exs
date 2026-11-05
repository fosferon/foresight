defmodule Foresight.Evals.RecallQualityTest do
  use ExUnit.Case, async: true

  alias Foresight.Evals.RecallQuality

  test "matches exact corpus text for every scenario" do
    for scenario <- RecallQuality.scenarios() do
      assert RecallQuality.matches_text?(scenario, scenario.expected_text),
             "expected exact match for #{scenario.id}"
    end
  end

  test "accepts normalized hindsight-style phrasing on the correction frontier" do
    scenario =
      RecallQuality.scenarios()
      |> Enum.find(&(&1.id == "stale-vs-corrected"))

    assert RecallQuality.matches_text?(
             scenario,
             "Foresight launch was not approved for immediate execution and cutover was delayed until the LMStudio reflect lane was proven. | When: on July 05, 2026"
           )
  end

  test "accepts normalized hindsight-style phrasing for fallback posture" do
    scenario =
      RecallQuality.scenarios()
      |> Enum.find(&(&1.id == "fallback-purpose"))

    assert RecallQuality.matches_text?(
             scenario,
             "Python Hindsight authority was kept live as a fallback during the qualification of the Foresight recall and reflect lane. | When: on July 5, 2026"
           )
  end

  test "accepts normalized phrasing for port-instability being a false gate" do
    scenario =
      RecallQuality.scenarios()
      |> Enum.find(&(&1.id == "port-instability-not-gate"))

    assert RecallQuality.matches_text?(
             scenario,
             "Port instability was not the real reason for the delay; the governing gate was proving recall and reflect quality on diary-style memory."
           )
  end

  test "rejects contradictory distractor text for launch approval questions" do
    scenario =
      RecallQuality.scenarios()
      |> Enum.find(&(&1.id == "not-immediate-launch"))

    refute RecallQuality.matches_text?(
             scenario,
             "Foresight approved an immediate launch due to the qualification soak not being finished. | Involving: Mira"
           )
  end

  test "reflect matcher accepts grounded contradiction answer" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-not-immediate-launch"))

    assert RecallQuality.matches_reflect_text?(
             scenario,
             "After Oxford, we did not approve shipping Foresight immediately; we delayed cutover until the LMStudio reflect lane was proven."
           )
  end

  test "reflect matcher rejects contradictory launch-approval answer" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-not-immediate-launch"))

    refute RecallQuality.matches_reflect_text?(
             scenario,
             "After Oxford, we approved an immediate launch and planned to ship Foresight right away."
           )
  end

  test "reflect matcher rejects next-week-only answer for schedule frontier" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-next-week-not-the-plan"))

    refute RecallQuality.matches_reflect_text?(
             scenario,
             "Yes, we simply moved the Foresight launch to next week after Oxford."
           )
  end

  test "reflect matcher accepts latest fallback posture answer" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-latest-position"))

    assert RecallQuality.matches_reflect_text?(
             scenario,
             "The latest posture was to keep the Python Hindsight fallback in place and cut helios-diary over only after Foresight proved industrial-strength recall and reflect quality."
           )
  end

  test "reflect matcher accepts port-instability clarification answer" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-port-instability-not-gate"))

    assert RecallQuality.matches_reflect_text?(
             scenario,
             "Port instability came up, but it was not the governing gate; we delayed cutover until recall and reflect quality on diary-style memory were proven."
           )
  end

  test "reflect matcher accepts alternate port-instability negation phrasing" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-port-instability-not-gate"))

    assert RecallQuality.matches_reflect_text?(
             scenario,
             "Foresight cutover after Oxford was delayed due to proving industrial-strength recall and reflect quality on diary-style memory via LMStudio reflect lane, not authority port instability."
           )
  end

  test "reflect matcher accepts fallback-purpose answer" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-fallback-purpose"))

    assert RecallQuality.matches_reflect_text?(
             scenario,
             "We kept the Python Hindsight authority live as a fallback while the Foresight memory path was still being qualified."
           )
  end

  test "reflect matcher accepts real-gate-over-schedule answer" do
    scenario =
      RecallQuality.reflect_scenarios()
      |> Enum.find(&(&1.id == "reflect-real-gate-over-schedule"))

    assert RecallQuality.matches_reflect_text?(
             scenario,
             "For helios-diary, the real gate was industrial-strength recall and reflect quality on diary-style memory, not schedule chatter or authority-port noise."
           )
  end
end
