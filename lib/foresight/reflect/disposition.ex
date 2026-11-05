defmodule Foresight.Reflect.Disposition do
  @moduledoc """
  Render a bank's disposition traits into behavioural prose for the reflect prompt.
  Faithful port of Hindsight's `engine/search/think_utils.py`
  `build_disposition_description` + `describe_trait_level`, activating the stored
  `disposition_skepticism` / `disposition_literalism` / `disposition_empathy` fields that
  were otherwise inert.

  Traits are levels 1-5 (1=trusting/flexible/detached, 5=skeptical/literal/empathetic).
  Deviation from Hindsight (intentional): an absent disposition renders `""` rather than
  Hindsight's always-present 3/3/3 default, so banks that set no disposition keep a clean
  prompt. Once ANY trait is present, all three render — a missing one defaults to moderate
  (level 3), matching Hindsight's `.get(value, desc[3])`.
  """

  @skepticism %{
    1 => "You are very trusting and tend to take information at face value.",
    2 => "You tend to trust information but may question obvious inconsistencies.",
    3 => "You have a balanced approach to information, neither too trusting nor too skeptical.",
    4 => "You are somewhat skeptical and often question the reliability of information.",
    5 =>
      "You are highly skeptical and critically examine all information for accuracy and hidden motives."
  }

  @literalism %{
    1 =>
      "You interpret information very flexibly, reading between the lines and inferring intent.",
    2 => "You tend to consider context and implied meaning alongside literal statements.",
    3 => "You balance literal interpretation with contextual understanding.",
    4 => "You prefer to interpret information more literally and precisely.",
    5 => "You interpret information very literally and focus on exact wording and commitments."
  }

  @empathy %{
    1 => "You focus primarily on facts and data, setting aside emotional context.",
    2 => "You consider facts first but acknowledge emotional factors exist.",
    3 => "You balance factual analysis with emotional understanding.",
    4 => "You give significant weight to emotional context and human factors.",
    5 =>
      "You strongly consider the emotional state and circumstances of others when forming memories."
  }

  @levels %{1 => "very low", 2 => "low", 3 => "moderate", 4 => "high", 5 => "very high"}

  @doc "Prose describing the disposition, or `\"\"` when none is set."
  @spec describe(map() | nil) :: String.t()
  def describe(nil), do: ""

  def describe(disposition) when is_map(disposition) do
    skepticism = level(disposition, "skepticism")
    literalism = level(disposition, "literalism")
    empathy = level(disposition, "empathy")

    if is_nil(skepticism) and is_nil(literalism) and is_nil(empathy) do
      ""
    else
      "Your disposition traits:\n" <>
        line("Skepticism", @skepticism, skepticism || 3) <>
        "\n" <>
        line("Literalism", @literalism, literalism || 3) <>
        "\n" <>
        line("Empathy", @empathy, empathy || 3)
    end
  end

  def describe(_other), do: ""

  defp line(name, table, level) do
    "- #{name} (#{Map.get(@levels, level, "moderate")}): #{Map.get(table, level, table[3])}"
  end

  # Look up a trait level under the bare name, the atom name, or the disposition_-prefixed
  # config-field name; coerce to an integer. `nil` when absent/unparseable.
  defp level(disposition, name) do
    disposition
    |> fetch_any([name, String.to_atom(name), "disposition_#{name}", :"disposition_#{name}"])
    |> to_level()
  end

  defp fetch_any(_map, []), do: nil

  defp fetch_any(map, [key | rest]) do
    case Map.get(map, key) do
      nil -> fetch_any(map, rest)
      value -> value
    end
  end

  defp to_level(value) when is_integer(value), do: value

  defp to_level(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp to_level(_other), do: nil
end
