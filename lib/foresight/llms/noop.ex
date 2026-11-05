defmodule Foresight.LLMs.Noop do
  @moduledoc false

  @behaviour Foresight.LLM

  @impl true
  def complete_structured(prompt, _messages, response_module, _opts) do
    if response_module == Foresight.Prompts.ReflectPlanResponse do
      {:ok,
       struct(response_module,
         focus_query: prompt[:query] || "",
         needs_consolidation: false,
         answer_ready: true,
         reason: "noop planner"
       )}
    else
      query = prompt[:query] || ""
      mission = get_in(prompt, [:bank, :mission]) || ""
      disposition = get_in(prompt, [:bank, :disposition]) || %{}

      summary =
        prompt[:recalled]
        |> List.wrap()
        |> Enum.take(2)
        |> Enum.map_join(" | ", fn item -> item["content"] || item[:content] || "" end)

      text =
        [query, mission, disposition_fragment(disposition), summary]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" :: ")

      {:ok,
       struct(response_module,
         text: text,
         directive_compliance: %{"status" => "followed", "notes" => "noop"},
         memory_ids:
           prompt[:recalled]
           |> List.wrap()
           |> Enum.reject(&((&1["type"] || &1[:type]) == "observation"))
           |> Enum.map(&(&1["id"] || &1[:id]))
           |> Enum.reject(&is_nil/1)
           |> Enum.take(2),
         mental_model_ids:
           prompt[:mental_models]
           |> List.wrap()
           |> Enum.map(&(&1["id"] || &1[:id]))
           |> Enum.reject(&is_nil/1)
           |> Enum.take(2),
         observation_ids:
           prompt[:observations]
           |> Map.get("observations", [])
           |> Enum.map(&(&1["id"] || &1[:id]))
           |> Enum.reject(&is_nil/1)
           |> Enum.take(2)
       )}
    end
  end

  @impl true
  def complete_json_schema(prompt, _messages, schema, _opts) do
    query = prompt[:query] || ""
    answer_text = prompt[:text] || prompt[:answer_text] || query

    {:ok, materialize_schema(schema, "#{answer_text}")}
  end

  defp disposition_fragment(disposition) when map_size(disposition) == 0, do: nil

  defp disposition_fragment(disposition) do
    disposition
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp materialize_schema(%{"type" => "object", "properties" => properties}, seed) do
    Map.new(properties, fn {key, property} -> {key, materialize_value(property, seed)} end)
  end

  defp materialize_schema(_schema, seed), do: %{"text" => seed}

  defp materialize_value(%{"type" => "string"}, seed), do: seed
  defp materialize_value(%{"type" => "boolean"}, _seed), do: true
  defp materialize_value(%{"type" => "integer"}, _seed), do: 1
  defp materialize_value(%{"type" => "number"}, _seed), do: 1.0
  defp materialize_value(%{"type" => "array"}, _seed), do: []

  defp materialize_value(%{"type" => "object", "properties" => properties}, seed),
    do: materialize_schema(%{"type" => "object", "properties" => properties}, seed)

  defp materialize_value(_property, seed), do: seed
end
