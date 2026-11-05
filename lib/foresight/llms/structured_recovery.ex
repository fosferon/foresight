defmodule Foresight.LLMs.StructuredRecovery do
  @moduledoc """
  Recover structured JSON from local-LLM output that strict schema parsing
  rejected.

  Ollama-served models routinely wrap their JSON object in a json fence and
  occasionally leave a trailing comma before a closing brace/bracket, despite
  being sent a `response_format`. LlmCore's strict structured-output parse then
  fails even though the body is otherwise valid and complete. The error tuple
  carries the raw body, so this module best-effort strips the fence + trailing
  commas and re-decodes. Shared by retain fact extraction and consolidation.
  """

  @doc """
  Try to decode a valid map from the error reason a `complete_json_schema` call
  returned. Returns `{:ok, decoded_map}` or `:error`.
  """
  @spec recover(term()) :: {:ok, map()} | :error
  def recover(reason) do
    with raw when is_binary(raw) <- raw_from_error(reason),
         {:ok, decoded} when is_map(decoded) <- decode_lenient(raw) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  @doc """
  Like `recover/1`, but casts the recovered map into `module`'s struct using the
  same string-key → struct-field mapping `Foresight.LLMs.LlmCore.complete_structured`
  uses on the happy path. Lets the reflect agentic loop's structured calls survive a
  JSON-fenced body from models like gpt-oss:20b instead of hard-failing the whole
  reflect (fairness). Returns `{:ok, struct}` or `:error` so the caller keeps
  its original error when recovery is impossible.
  """
  @spec recover_struct(term(), module()) :: {:ok, struct()} | :error
  def recover_struct(reason, module) when is_atom(module) do
    case recover(reason) do
      {:ok, map} -> {:ok, to_struct(module, map)}
      :error -> :error
    end
  end

  defp to_struct(module, map) do
    allowed = module.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))

    attrs =
      Enum.reduce(allowed, %{}, fn key, acc ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    struct(module, attrs)
  end

  @doc "Pull the raw model body out of the known structured-output error shapes."
  @spec raw_from_error(term()) :: String.t() | nil
  def raw_from_error({:structured_output_error, {:invalid_json, %{data: raw}}})
      when is_binary(raw),
      do: raw

  def raw_from_error(%{data: raw}) when is_binary(raw), do: raw
  def raw_from_error(_other), do: nil

  @doc """
  Strip a surrounding markdown code fence and trailing commas, then JSON-decode.
  Best-effort: returns `{:ok, term}` or `{:error, reason}` (from `Jason.decode/1`).
  """
  @spec decode_lenient(String.t()) :: {:ok, term()} | {:error, term()}
  def decode_lenient(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.replace(~r/,(\s*[}\]])/, "\\1")
    |> String.trim()
    |> Jason.decode()
  end
end
