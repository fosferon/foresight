defmodule Foresight.Reflect.CitationSelection do
  @moduledoc """
  Filter the LLM's declared citations (from the terminal `done` tool's args) down
  to those that were actually retrieved during the reflect loop.

  The agentic path previously cited EVERY retrieved id (process-dict accumulation)
  — over-citation. With the terminal `done` tool (llm_core `terminal_tool`), the
  model declares which ids it actually used; we keep only the intersection with
  what was retrieved. This drops both over-citation (retrieved but not cited) and
  hallucinated citations (cited but never retrieved), mirroring Hindsight's
  done-tool id filter.
  """

  @typedoc "Retrieved grounding ids, per tier (string ids)."
  @type retrieved :: %{
          required(:memory) => [String.t()],
          required(:observation) => [String.t()],
          required(:mental_model) => [String.t()]
        }

  @doc """
  Select the cited ids per tier, keeping only ids present in `retrieved`.

  `terminal_args` is the raw `done` tool arguments (string keys
  `"memory_ids"` / `"observation_ids"` / `"mental_model_ids"`). Results preserve
  the retrieved order (deterministic, aligns with `based_on`).
  """
  @spec select(map(), retrieved()) :: retrieved()
  def select(terminal_args, retrieved) when is_map(terminal_args) and is_map(retrieved) do
    %{
      memory: keep_retrieved(terminal_args["memory_ids"], retrieved.memory),
      observation: keep_retrieved(terminal_args["observation_ids"], retrieved.observation),
      mental_model: keep_retrieved(terminal_args["mental_model_ids"], retrieved.mental_model)
    }
  end

  defp keep_retrieved(cited, retrieved) when is_list(retrieved) do
    cited_set =
      cited
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    Enum.filter(retrieved, &MapSet.member?(cited_set, &1))
  end
end
