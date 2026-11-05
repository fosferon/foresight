defmodule Foresight.AsyncQueue do
  @moduledoc false

  alias Foresight.Backend
  alias Foresight.Context

  @callback enqueue_retain(Context.t(), map(), keyword()) :: Backend.result()
  @callback enqueue_consolidate(Context.t(), map(), keyword()) :: Backend.result()
  @callback enqueue_embedding_backfill(Context.t(), map(), keyword()) :: Backend.result()
  @callback enqueue_refresh_mental_model(Context.t(), map(), keyword()) :: Backend.result()
  @callback enqueue_migrate_bank(Context.t(), map(), keyword()) :: Backend.result()
  @callback enqueue_probe_bank(Context.t(), map(), keyword()) :: Backend.result()
  @callback list_operations(Context.t(), map(), keyword()) :: Backend.result()
  @callback get_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback cancel_operation(Context.t(), String.t(), keyword()) :: Backend.result()
  @callback retry_operation(Context.t(), String.t(), keyword()) :: Backend.result()
end
