defmodule Foresight.DocumentConverters.Text do
  @moduledoc false

  # Documents that already are text — the shape a Hindsight migration carries by
  # construction. Nothing to convert: the body is the document.

  @behaviour Foresight.DocumentConverter

  alias Foresight.Error

  @impl true
  def convert(%{"text" => text} = file_input, _opts) when is_binary(text) do
    # Retain silently drops items with no alphanumeric content, and an all-blank batch
    # fails: a blank document would vanish from a migration without a trace. Say so.
    if Regex.match?(~r/[[:alnum:]]/u, text) do
      {:ok, converted(text, file_input)}
    else
      {:error,
       Error.new(:invalid_request, %{message: "text document contains no alphanumeric content"})}
    end
  end

  def convert(_file_input, _opts) do
    {:error, Error.new(:invalid_request, %{message: "text conversion requires a \"text\" body"})}
  end

  defp converted(text, file_input) do
    %{
      text: text,
      title: file_input["title"] || file_input["filename"],
      metadata: %{"source" => "text"},
      content_type: file_input["content_type"] || "text/plain",
      chunks: []
    }
  end
end
