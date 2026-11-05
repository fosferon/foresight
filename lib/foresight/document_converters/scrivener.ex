defmodule Foresight.DocumentConverters.Scrivener do
  @moduledoc false

  @behaviour Foresight.DocumentConverter

  alias Foresight.Error
  alias Foresight.Ingestion.Scrivener

  @impl true
  def convert(%{"path" => path} = file_input, opts) when is_binary(path) do
    with {:ok, project} <- Scrivener.parse(path, opts) do
      {:ok,
       %{
         text: document_text(project.scenes),
         title: project.title || file_input["filename"] || Path.basename(path),
         metadata: %{
           "source" => "scrivener",
           "scrivener_path" => project.path,
           "scrivx_path" => project.scrivx_path,
           "scrivener_identifier" => project.identifier,
           "scene_count" => length(project.scenes)
         },
         content_type:
           file_input["content_type"] || "application/vnd.literatureandlatte.scrivener",
         chunks: Enum.map(project.scenes, &scene_chunk/1)
       }}
    end
  end

  def convert(_file_input, _opts) do
    {:error,
     Error.new(:invalid_request, %{message: "scrivener conversion requires a .scriv path"})}
  end

  defp document_text(scenes) do
    scenes
    |> Enum.map(fn scene ->
      [scene.title, scene.text]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")
    end)
    |> Enum.join("\n\n")
  end

  defp scene_chunk(scene) do
    %{
      "text" => scene.text,
      "source" => "scrivener",
      "binder_path" => scene.binder_path,
      "title" => scene.title || "",
      "synopsis" => scene.synopsis,
      "uuid" => scene.uuid,
      "order_index" => scene.order_index,
      "sibling_index" => scene.sibling_index,
      "label_id" => scene.label_id,
      "keyword_ids" => scene.keyword_ids
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_value), do: false
end
