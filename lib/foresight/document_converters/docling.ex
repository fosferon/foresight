defmodule Foresight.DocumentConverters.Docling do
  @moduledoc false

  @behaviour Foresight.DocumentConverter

  alias Foresight.Error

  @impl true
  def convert(%{"path" => path} = file_input, opts) when is_binary(path) do
    worker = Keyword.get(opts, :docling_worker, Foresight.Ingestion.DoclingWorker)

    case worker.parse_with_metadata(path) do
      {:ok, %{markdown: markdown, metadata: metadata} = result} ->
        {:ok,
         %{
           text: markdown,
           title:
             Map.get(metadata, :title) || Map.get(metadata, "title") || file_input["filename"],
           metadata: normalize_metadata(metadata),
           content_type: file_input["content_type"],
           # Structural chunks (with per-chunk source_location) when docling exposed
           # document structure; empty when it only produced flat markdown.
           chunks: Map.get(result, :chunks, [])
         }}

      {:ok, markdown} when is_binary(markdown) ->
        {:ok,
         %{
           text: markdown,
           title: file_input["filename"],
           metadata: %{},
           content_type: file_input["content_type"]
         }}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:invalid_request, %{message: to_string(reason)})}
    end
  end

  def convert(_file_input, _opts) do
    {:error, Error.new(:invalid_request, %{message: "docling conversion requires a file path"})}
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_metadata(_metadata), do: %{}
end
