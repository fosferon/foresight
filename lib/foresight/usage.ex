defmodule Foresight.Usage do
  @moduledoc """
  Ledger of the chargeable calls made while serving one operation.

  Retain and recall open a ledger in the calling process, the LLM adapter and the
  remote embedder record every call they make into it, and the operation closes it
  and reports the entries on its result under `"usage"`. Each entry names the kind
  of call, the provider and model, the token counts the provider reported, the
  request id when one was returned, and whether the call succeeded, so a consumer
  can attribute cost deterministically and audit it against the provider's own
  records.

  `"usage"` is `nil` when no chargeable call happened: local embedders and the Noop
  LLM record nothing, so the default configuration is unchanged.
  """

  @key :foresight_usage_ledger

  @type entry :: %{required(String.t()) => term()}

  @doc "Open a fresh ledger in the current process."
  @spec start() :: :ok
  def start do
    Process.put(@key, [])
    :ok
  end

  @doc """
  Record one call. A no-op when no ledger is open, so adapters can always call it.
  Missing token counts default to zero; `"status"` defaults to `"ok"`.
  """
  @spec record(map()) :: :ok
  def record(entry) when is_map(entry) do
    case Process.get(@key) do
      nil -> :ok
      entries -> Process.put(@key, [normalize(entry) | entries])
    end

    :ok
  end

  @doc "Close the ledger and return its entries in call order."
  @spec drain() :: [entry()]
  def drain do
    entries = Process.get(@key) || []
    Process.delete(@key)
    Enum.reverse(entries)
  end

  @doc """
  Summarise entries for a result: token totals over successful calls plus the
  calls themselves. `nil` for an empty ledger.
  """
  @spec report([entry()]) :: map() | nil
  def report([]), do: nil

  def report(entries) when is_list(entries) do
    ok = Enum.filter(entries, &(&1["status"] == "ok"))

    %{
      "input_tokens" => sum(ok, "input_tokens"),
      "output_tokens" => sum(ok, "output_tokens"),
      "total_tokens" => sum(ok, "total_tokens"),
      "calls" => entries,
      "failed_calls" => length(entries) - length(ok)
    }
  end

  @doc "Build an LLM entry from an `LlmCore.LLM.Response`-shaped struct or map."
  @spec llm_entry(map(), atom() | String.t() | nil) :: entry()
  def llm_entry(response, role) do
    usage = Map.get(response, :usage) || %{}

    %{
      "kind" => "llm",
      "role" => stringify(role),
      "provider" => stringify(Map.get(response, :provider)),
      "model" => Map.get(response, :model),
      "input_tokens" => token(usage, [:prompt_tokens, :input_tokens]),
      "output_tokens" => token(usage, [:completion_tokens, :output_tokens]),
      "total_tokens" => token(usage, [:total_tokens]),
      "request_id" => request_id(Map.get(response, :metadata), Map.get(response, :raw)),
      "status" => "ok"
    }
  end

  @doc "Build an LLM entry for a call that failed before any usage was reported."
  @spec llm_error_entry(term(), atom() | String.t() | nil) :: entry()
  def llm_error_entry(provider, role) do
    %{
      "kind" => "llm",
      "role" => stringify(role),
      "provider" => stringify(provider),
      "model" => nil,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "request_id" => nil,
      "status" => "error"
    }
  end

  defp normalize(entry) do
    entry
    |> Map.put_new("status", "ok")
    |> Map.update("input_tokens", 0, &(&1 || 0))
    |> Map.update("output_tokens", 0, &(&1 || 0))
    |> Map.update("total_tokens", 0, &(&1 || 0))
  end

  defp sum(entries, key), do: Enum.reduce(entries, 0, &((&1[key] || 0) + &2))

  defp token(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(usage, key) || Map.get(usage, to_string(key)) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp request_id(metadata, raw) do
    [metadata, raw]
    |> Enum.filter(&is_map/1)
    |> Enum.find_value(fn map ->
      Map.get(map, :request_id) || Map.get(map, "request_id") || Map.get(map, "id")
    end)
    |> case do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
