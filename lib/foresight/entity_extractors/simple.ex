defmodule Foresight.EntityExtractors.Simple do
  @moduledoc false

  @behaviour Foresight.EntityExtractor

  # Labels the retain fact assembler writes into every stored fact
  # (`what | When: x | Involving: y`, Foresight.Prompts.Retain.V1.build_fact_text/1).
  # They are capitalised, so the entity regex below would read them as entities of
  # every fact in the bank.
  @fact_labels ~r/\b(?:When|Involving):/

  @impl true
  @spec extract(String.t()) :: [String.t()]
  def extract(content) when is_binary(content) do
    content
    |> String.replace(@fact_labels, " ")
    |> then(&Regex.scan(~r/\b[A-Z][A-Za-z0-9_-]{2,}\b/, &1))
    |> List.flatten()
    |> Enum.uniq()
  end
end
