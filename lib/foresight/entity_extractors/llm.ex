defmodule Foresight.EntityExtractors.LLM do
  @moduledoc """
  LLM-backed fallback entity extractor.

  Used ONLY on the path where retain-time atomic-fact extraction is off, so
  items carry no `fact.entities` and the seam would otherwise fall back to the regex
  `Simple`. It asks a `complete_json_schema/4`-capable LLM for the salient named
  entities in the content.

  This is a Foresight convenience, not a Hindsight port: Hindsight's slim path has no
  standalone NER pass — its entities come from `fact.entities`. Faithful to the rest
  of the pipeline's LlmCore isolation, it DEGRADES to `Simple` when the LLM is
  absent/incapable, on any error, timeout, or unparseable result — extraction never
  fails a retain. A COMPETENT empty result (`{"entities": []}`) is respected as "no
  entities" and returned as `[]`, not backfilled with regex noise, mirroring the
  `fact.entities or []` discipline in `Retain.FactExtraction`.
  """

  @behaviour Foresight.EntityExtractor

  alias Foresight.EntityExtractors.Simple
  alias Foresight.LLMs.StructuredRecovery

  require Logger

  # Hindsight hardcodes a low temperature for reproducible extraction; 1024 tokens is
  # ample for an entity list (far smaller than fact extraction's chunked output).
  @temperature 0.1
  @max_tokens 1024

  @impl true
  def extract(content) when is_binary(content), do: extract(content, [])

  @impl true
  def extract(content, opts) when is_binary(content) and is_list(opts) do
    llm = opts[:llm]

    if capable?(llm) do
      case safe_complete(llm, content, opts) do
        {:ok, names} -> names
        :error -> Simple.extract(content)
      end
    else
      Simple.extract(content)
    end
  end

  # Mirrors `Retain.FactExtraction.extractable?/1`: a loaded module exporting the
  # structured-output callback.
  defp capable?(llm) do
    is_atom(llm) and not is_nil(llm) and Code.ensure_loaded?(llm) and
      function_exported?(llm, :complete_json_schema, 4)
  end

  # `{:ok, names}` on a valid entities list (possibly empty — respected); `:error` on
  # an LLM error or a non-`entities` response, which the caller degrades to `Simple`.
  defp safe_complete(llm, content, opts) do
    prompt = %{query: "entities.extract", content: content}

    case llm.complete_json_schema(prompt, messages(content), schema(), llm_opts(opts)) do
      {:ok, %{"entities" => list}} when is_list(list) ->
        {:ok, normalize(list)}

      {:ok, _other} ->
        :error

      {:error, reason} ->
        # Ollama-served models routinely fence their JSON despite response_format,
        # tripping the strict parse; the error carries the raw body, so try to recover
        # entities from it before degrading.
        case StructuredRecovery.recover(reason) do
          {:ok, %{"entities" => list}} when is_list(list) ->
            {:ok, normalize(list)}

          _ ->
            Logger.warning(
              "LLM entity extraction failed; using regex fallback: #{inspect(reason)}"
            )

            :error
        end
    end
  rescue
    error ->
      Logger.warning("LLM entity extraction crashed; using regex fallback: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("LLM entity extraction exited; using regex fallback: #{inspect(reason)}")
      :error
  end

  # Tolerant of bare strings and the {name/text => ...} object shape (same normalisation
  # as `Retain.FactExtraction.fact_entities/1`); trimmed, non-empty, order-preserving,
  # de-duplicated by name.
  defp normalize(list) do
    list
    |> Enum.map(&entry_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp entry_name(name) when is_binary(name), do: String.trim(name)
  defp entry_name(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp entry_name(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp entry_name(_other), do: ""

  defp messages(content) do
    system =
      "Extract the salient named entities from the text: people, organizations, " <>
        "locations, events, products, and the few key concepts worth remembering " <>
        "long-term. Be selective — proper nouns and significant concepts only, not " <>
        "common words. Respond as JSON {\"entities\": [...]} of unique entity-name " <>
        "strings. Return an empty list if there are none."

    [%{role: :system, content: system}, %{role: :user, content: content}]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["entities"],
      "properties" => %{
        "entities" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }
  end

  # Inject the extraction defaults into provider_opts unless the caller set them, and
  # forward only non-nil provider hints (a nil provider_opts would crash LlmCore's
  # Keyword.merge). Mirrors `Retain.FactExtraction.llm_opts/1`.
  defp llm_opts(opts) do
    provider_opts =
      (opts[:provider_opts] || [])
      |> put_default(:temperature, @temperature)
      |> put_default(:max_tokens, @max_tokens)

    opts
    |> Keyword.take([:provider, :sleep_ms])
    |> Keyword.put(:provider_opts, provider_opts)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp put_default(kw, key, default) do
    case Keyword.get(kw, key) do
      nil -> Keyword.put(kw, key, default)
      _present -> kw
    end
  end
end
