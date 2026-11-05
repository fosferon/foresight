defmodule Foresight.Tokenizers.Cl100kBaseTest do
  use ExUnit.Case, async: false

  alias Foresight.Tokenizers.Cl100kBase

  @moduletag :ml

  test "matches the fixed cl100k_base parity corpus" do
    corpus_path =
      Path.expand("../../../priv/foresight/fixtures/tokenizer/cl100k_base_corpus.json", __DIR__)

    corpus = corpus_path |> File.read!() |> Jason.decode!()

    for %{"text" => text, "count" => expected_count} <- corpus do
      assert {:ok, ^expected_count} = Cl100kBase.count(text)
      assert {:ok, ids} = Cl100kBase.encode(text)
      assert length(ids) == expected_count
    end
  end
end
