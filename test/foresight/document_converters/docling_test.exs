defmodule Foresight.DocumentConverters.DoclingTest do
  use ExUnit.Case, async: true

  alias Foresight.DocumentConverters.Docling

  defmodule FakeDoclingWorker do
    def parse_with_metadata(path) do
      {:ok,
       %{
         markdown: "# Converted\n\n#{path}",
         metadata: %{"title" => "Converted Title", "format" => ".pdf"}
       }}
    end
  end

  test "converts a file through the configured docling worker" do
    assert {:ok, conversion} =
             Docling.convert(
               %{
                 "path" => "/tmp/example.pdf",
                 "filename" => "example.pdf",
                 "content_type" => "application/pdf"
               },
               docling_worker: FakeDoclingWorker
             )

    assert conversion.text == "# Converted\n\n/tmp/example.pdf"
    assert conversion.title == "Converted Title"
    assert conversion.content_type == "application/pdf"
    assert conversion.metadata == %{"title" => "Converted Title", "format" => ".pdf"}
  end
end
