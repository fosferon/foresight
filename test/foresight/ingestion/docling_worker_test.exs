defmodule Foresight.Ingestion.DoclingWorkerTest do
  use ExUnit.Case, async: true

  alias Foresight.Ingestion.DoclingWorker

  test "normalizes erlport charlist tuple responses" do
    response = {
      ~c"ok",
      %{
        ~c"markdown" => ~c"# Converted\n\nhello",
        ~c"metadata" => %{~c"title" => ~c"Converted Title", ~c"format" => ~c".pdf"}
      }
    }

    assert {:ok,
            %{
              markdown: "# Converted\n\nhello",
              metadata: %{"title" => "Converted Title", "format" => ".pdf"}
            }} = DoclingWorker.normalize_python_response(response)
  end

  test "normalizes erlport error tuples" do
    assert {:error, "boom"} = DoclingWorker.normalize_python_response({~c"error", ~c"boom"})
  end
end
