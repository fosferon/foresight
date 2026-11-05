defmodule Foresight.ML.ServingTest do
  use ExUnit.Case, async: false

  alias Foresight.Embedders.Bumblebee, as: BumblebeeEmbedder

  @moduletag :ml
  @moduletag timeout: 300_000

  test "loads bge-small-en-v1.5 as a supervised text embedding serving" do
    serving_name = Module.concat(__MODULE__, Serving)

    start_supervised!(
      {Foresight.ML.Serving,
       name: serving_name,
       model_id: "BAAI/bge-small-en-v1.5",
       output_attribute: :hidden_state,
       output_pool: :mean_pooling,
       embedding_processor: :l2_norm}
    )

    assert {:ok, embedding} =
             BumblebeeEmbedder.embed("foresight smoke test", serving: serving_name)

    assert length(embedding) == 384

    norm =
      embedding
      |> Enum.reduce(0.0, fn value, acc -> acc + value * value end)
      |> :math.sqrt()

    assert_in_delta norm, 1.0, 1.0e-3
  end

  test "accepts map-backed :foresight, :ml config like FullMLAuthority" do
    previous_ml = Application.get_env(:foresight, :ml)
    serving_name = Module.concat(__MODULE__, MapConfigServing)

    Application.put_env(:foresight, :ml, %{
      enabled: true,
      model_id: "BAAI/bge-small-en-v1.5",
      output_attribute: :hidden_state,
      output_pool: :mean_pooling,
      embedding_processor: :l2_norm
    })

    on_exit(fn ->
      if is_nil(previous_ml) do
        Application.delete_env(:foresight, :ml)
      else
        Application.put_env(:foresight, :ml, previous_ml)
      end
    end)

    start_supervised!({Foresight.ML.Serving, name: serving_name})

    assert {:ok, embedding} =
             BumblebeeEmbedder.embed("foresight map-backed config smoke test",
               serving: serving_name
             )

    assert length(embedding) == 384
  end

  test "embeds many texts through the same supervised serving" do
    serving_name = Module.concat(__MODULE__, BatchServing)

    start_supervised!(
      {Foresight.ML.Serving,
       name: serving_name,
       model_id: "BAAI/bge-small-en-v1.5",
       output_attribute: :hidden_state,
       output_pool: :mean_pooling,
       embedding_processor: :l2_norm}
    )

    assert {:ok, embeddings} =
             BumblebeeEmbedder.embed_many(
               [
                 "foresight batch smoke test one",
                 "foresight batch smoke test two",
                 "foresight batch smoke test three"
               ],
               serving: serving_name
             )

    assert length(embeddings) == 3
    assert Enum.all?(embeddings, &(length(&1) == 384))
  end
end
