defmodule Foresight.Config.Guard do
  @moduledoc false

  alias Foresight.Config.Fields
  alias Foresight.Error

  @native_language_pattern ~r/\A[\p{L}\p{M}\s\-'().,]{1,64}\z/u
  @blocked_fragments ["\n", "\r", "`", ";", "--", "/*", "*/", "{", "}", "<", ">"]

  @spec validate_updates(map()) :: :ok | {:error, Error.t()}
  def validate_updates(updates) when is_map(updates) do
    normalized = Fields.normalize_layer(updates)

    case Map.get(normalized, "native_language") do
      nil ->
        :ok

      native_language when is_binary(native_language) ->
        validate_native_language(native_language)

      _other ->
        invalid_native_language()
    end
  end

  def validate_updates(_updates), do: :ok

  defp validate_native_language(native_language) do
    trimmed = String.trim(native_language)

    cond do
      trimmed == "" ->
        invalid_native_language()

      not String.match?(trimmed, @native_language_pattern) ->
        invalid_native_language()

      Enum.any?(@blocked_fragments, &String.contains?(trimmed, &1)) ->
        invalid_native_language()

      true ->
        :ok
    end
  end

  defp invalid_native_language do
    {:error,
     Error.new(:invalid_request, %{
       message:
         "native_language contains unsafe content; use a short natural-language label such as 'English' or 'Greek'"
     })}
  end
end
