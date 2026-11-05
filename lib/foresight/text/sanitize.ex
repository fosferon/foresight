defmodule Foresight.Text.Sanitize do
  @moduledoc """
  Scrubs model output of characters that break downstream systems.

  Removes ASCII control characters other than tab, newline and carriage return
  (they break JSON decoding and Postgres's UTF-8 encoding), the DEL character, and
  any bytes that are not valid UTF-8. Applied to every text the retain extractor
  and the consolidation merge take from a model before it is stored. Port of
  Hindsight's `sanitize_llm_output` (`engine/llm_wrapper.py`).
  """

  @control ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u

  @spec llm_output(String.t() | nil) :: String.t() | nil
  def llm_output(nil), do: nil
  def llm_output(""), do: ""

  def llm_output(text) when is_binary(text) do
    text
    |> ensure_valid_utf8()
    |> then(&Regex.replace(@control, &1, ""))
  end

  def llm_output(other), do: other

  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      text
      |> String.chunk(:valid)
      |> Enum.filter(&String.valid?/1)
      |> Enum.join()
    end
  end
end
