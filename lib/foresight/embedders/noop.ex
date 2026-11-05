defmodule Foresight.Embedders.Noop do
  @moduledoc false

  @behaviour Foresight.Embedder

  @default_dim 384

  @impl true
  def dimension(_opts), do: {:ok, @default_dim}

  @impl true
  def embed(text, _opts) when is_binary(text) do
    values =
      text
      |> :erlang.md5()
      |> :binary.bin_to_list()
      |> Stream.cycle()
      |> Enum.take(@default_dim)
      |> Enum.map(&(&1 / 255))

    {:ok, values}
  end
end
