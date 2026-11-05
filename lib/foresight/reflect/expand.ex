defmodule Foresight.Reflect.Expand do
  @moduledoc """
  The agentic reflect `expand` tool: drill previously retrieved memories up the
  hierarchy. `"chunk"` (the default) returns each memory with its provenance and
  the neighbouring memories of the same document, the surrounding context a
  truncated fact is missing; `"document"` returns the owning document's title and
  text. The id list is model-controlled, so it is de-duplicated, filtered to valid
  ids and capped before any query runs. `cited_ids/1` lists every memory id an
  expansion put in front of the model, for grounding.
  """

  import Ecto.Query

  alias Foresight.Schemas.Document
  alias Foresight.Schemas.MemoryUnit

  @max_ids 25
  @document_max_chars 8_000
  @chunk_neighbours 1

  @doc "Upper bound on memory ids expanded per call."
  @spec max_ids() :: pos_integer()
  def max_ids, do: @max_ids

  @doc "Normalise the tool's `depth` argument; anything but `\"document\"` is `\"chunk\"`."
  @spec depth(term()) :: String.t()
  def depth("document"), do: "document"
  def depth(_other), do: "chunk"

  @doc "Unique, well-formed memory ids, at most `max_ids/0` of them, in request order."
  @spec normalize_ids(term()) :: [String.t()]
  def normalize_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.take(@max_ids)
  end

  @doc "Every memory id an expansion surfaced: the expanded units and their neighbours."
  @spec cited_ids([map()]) :: [String.t()]
  def cited_ids(expanded) do
    expanded
    |> Enum.flat_map(fn entry ->
      neighbours =
        (get_in(entry, ["chunk", "before"]) || []) ++ (get_in(entry, ["chunk", "after"]) || [])

      [entry["id"] | Enum.map(neighbours, & &1["id"])]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Expand `ids` within `bank_id`. Must run inside the caller's tenant scope;
  `repo_opts` carries the tenant prefix.
  """
  @spec expand(module(), String.t(), term(), String.t(), keyword()) :: [map()]
  def expand(repo, bank_id, ids, depth, repo_opts) do
    case normalize_ids(ids) do
      [] ->
        []

      ids ->
        units =
          from(unit in MemoryUnit, where: unit.bank_id == ^bank_id and unit.id in ^ids)
          |> repo.all(repo_opts)

        context = load_context(repo, bank_id, units, depth, repo_opts)
        Enum.map(units, &render(&1, depth, context))
    end
  end

  defp load_context(_repo, _bank_id, [], _depth, _repo_opts), do: %{}

  defp load_context(repo, bank_id, units, "document", repo_opts) do
    case document_refs(units) do
      [] ->
        %{}

      refs ->
        from(document in Document,
          where: document.bank_id == ^bank_id and document.external_id in ^refs
        )
        |> repo.all(repo_opts)
        |> Map.new(&{&1.external_id, &1})
    end
  end

  defp load_context(repo, bank_id, units, "chunk", repo_opts) do
    case document_refs(units) do
      [] ->
        %{}

      refs ->
        # Same order list_document_chunks exposes, so neighbours here are the
        # neighbouring chunks there. Observations are derived, not chunks. Only ids
        # are loaded for the ordering; the few neighbours' texts come in a second,
        # id-bounded query, so a document with thousands of chunks costs ids, not text.
        ordered =
          from(unit in MemoryUnit,
            where:
              unit.bank_id == ^bank_id and unit.document_ref in ^refs and
                unit.fact_type != :observation,
            order_by: [asc: unit.inserted_at, asc: unit.id],
            select: {unit.document_ref, unit.id}
          )
          |> repo.all(repo_opts)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        neighbour_ids =
          units
          |> Enum.flat_map(fn unit ->
            neighbour_positions(Map.get(ordered, unit.document_ref, []), unit.id)
          end)
          |> Enum.uniq()

        texts =
          if neighbour_ids == [] do
            %{}
          else
            from(unit in MemoryUnit,
              where: unit.id in ^neighbour_ids,
              select: {unit.id, unit.content}
            )
            |> repo.all(repo_opts)
            |> Map.new()
          end

        %{ordered: ordered, texts: texts}
    end
  end

  # Ids of the chunks immediately before and after `id` in the document's order.
  defp neighbour_positions(ids, id) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil ->
        []

      index ->
        before_from = max(index - @chunk_neighbours, 0)

        Enum.slice(ids, before_from, index - before_from) ++
          (ids |> Enum.drop(index + 1) |> Enum.take(@chunk_neighbours))
    end
  end

  defp document_refs(units) do
    units |> Enum.map(& &1.document_ref) |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  defp render(unit, "document", documents) do
    unit
    |> base()
    |> put_present("document", document_context(Map.get(documents, unit.document_ref)))
  end

  defp render(unit, "chunk", %{ordered: ordered, texts: texts}) do
    unit
    |> base()
    |> put_present("chunk", chunk_context(unit, Map.get(ordered, unit.document_ref, []), texts))
  end

  defp render(unit, "chunk", _no_context), do: base(unit)

  defp base(unit) do
    %{"id" => to_string(unit.id), "content" => unit.content}
    |> put_present("document_ref", unit.document_ref)
    |> put_present("source_location", unit.source_location)
  end

  defp document_context(nil), do: nil

  defp document_context(%Document{} = document) do
    text = document.original_text || ""
    truncated? = String.length(text) > @document_max_chars

    %{
      "id" => document.external_id,
      "text" => if(truncated?, do: String.slice(text, 0, @document_max_chars), else: text),
      "truncated" => truncated?
    }
    |> put_present("title", document.title)
  end

  defp chunk_context(_unit, [], _texts), do: nil

  defp chunk_context(unit, ordered_ids, texts) do
    case Enum.find_index(ordered_ids, &(&1 == unit.id)) do
      nil ->
        nil

      index ->
        before_from = max(index - @chunk_neighbours, 0)

        %{
          "index" => index,
          "total" => length(ordered_ids),
          "before" =>
            ordered_ids
            |> Enum.slice(before_from, index - before_from)
            |> Enum.map(&neighbour(&1, texts)),
          "after" =>
            ordered_ids
            |> Enum.drop(index + 1)
            |> Enum.take(@chunk_neighbours)
            |> Enum.map(&neighbour(&1, texts))
        }
    end
  end

  # Neighbours carry their id so the model can cite them; the tool registers them
  # as retrieved grounding for that reason.
  defp neighbour(id, texts), do: %{"id" => to_string(id), "content" => Map.get(texts, id)}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
