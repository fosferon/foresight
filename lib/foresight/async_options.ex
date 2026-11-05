defmodule Foresight.AsyncOptions do
  @moduledoc false

  @job_key "foresight_options"
  @allowed_options [:rls_enabled]

  @spec dump(keyword()) :: %{optional(String.t()) => boolean()}
  def dump(opts) when is_list(opts) do
    Enum.reduce(@allowed_options, %{}, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when is_boolean(value) -> Map.put(acc, Atom.to_string(key), value)
        _other -> acc
      end
    end)
  end

  @spec put_job_options(map(), keyword()) :: map()
  def put_job_options(args, opts) when is_map(args) and is_list(opts) do
    case dump(opts) do
      options when map_size(options) == 0 -> args
      options -> Map.put(args, @job_key, options)
    end
  end

  @spec restore(map(), keyword()) :: keyword()
  def restore(args, opts) when is_map(args) and is_list(opts) do
    case get_in(args, [@job_key, "rls_enabled"]) do
      value when is_boolean(value) -> Keyword.put(opts, :rls_enabled, value)
      _other -> opts
    end
  end
end
