defmodule Foresight.Embeddings.ProfileTest do
  use ExUnit.Case, async: true

  alias Foresight.Embeddings.Profile

  defmodule FakeEmbedder do
    def dimension(_opts), do: {:ok, 384}
  end

  test "resolve/2 reads model_id from map-shaped runtime ml config" do
    previous_ml = Application.get_env(:foresight, :ml)
    Application.put_env(:foresight, :ml, %{model_id: "map-backed-model"})

    on_exit(fn ->
      if is_nil(previous_ml) do
        Application.delete_env(:foresight, :ml)
      else
        Application.put_env(:foresight, :ml, previous_ml)
      end
    end)

    assert {:ok, %{"model_id" => "map-backed-model", "embedding_dim" => 384}} =
             Profile.resolve(%{}, embedder: FakeEmbedder)
  end
end
