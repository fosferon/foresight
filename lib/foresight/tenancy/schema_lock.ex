defmodule Foresight.Tenancy.SchemaLock do
  @moduledoc false

  @spec with_slug(String.t(), (-> result)) :: result when result: var
  def with_slug(slug, fun) when is_binary(slug) and is_function(fun, 0) do
    lock_id = {{:foresight_tenant_schema, slug}, self()}

    try do
      true = :global.set_lock(lock_id, [node()], :infinity)
      fun.()
    after
      :global.del_lock(lock_id, [node()])
    end
  end
end
