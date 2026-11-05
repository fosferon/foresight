defmodule Foresight.Embeddings.Backfill do
  @moduledoc false

  alias Foresight.Error

  @spec run(Foresight.Context.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def run(ctx, payload, opts) do
    storage = Keyword.get(opts, :storage, Foresight.Storage.Ecto)

    # function_exported?/3 is false for a module that is not loaded yet, so make
    # sure the storage module is loaded before asking; an in-process call ahead
    # of the first Storage.Ecto use otherwise reported :not_implemented.
    if Code.ensure_loaded?(storage) and function_exported?(storage, :backfill_embeddings, 3) do
      storage.backfill_embeddings(ctx, payload, opts)
    else
      {:error,
       Error.new(:not_implemented, %{
         message: "#{inspect(storage)} does not implement backfill_embeddings/3"
       })}
    end
  end
end
