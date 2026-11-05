defmodule Foresight.Fitness.TenancyBoundary do
  @moduledoc false

  @engine_root Path.expand("../../..", __DIR__)
  @storage_file Path.join(@engine_root, "lib/foresight/storage/ecto.ex")
  @safe_wrappers [:with_tenant_scope, :with_tenant_role]
  @allowed_ctx_helpers [
    :bank_operation_stats,
    :insert_mutation_audit_log,
    :reflect_observations,
    :resolve_runtime_bank_config,
    :ranked_recall_items,
    :run_recall_strategy,
    :maybe_put_recall_strategy_db_role,
    :semantic_recall_items,
    :keyword_recall_items,
    :graph_recall_items,
    :source_expansion_seed_units,
    :graph_traversal_units,
    :temporal_recall_items,
    :temporal_traversal_items,
    # Always invoked inside create_mental_model/4's with_tenant_scope wrapper
    # (ecto.ex create_mental_model). The static scan is not caller-aware; a caller-aware
    # check would remove the need for this hand-maintained allowlist.
    :create_mental_model_placeholder
  ]

  @type violation :: %{file: String.t(), function: atom(), reason: String.t()}

  @spec violations() :: [violation()]
  def violations do
    violations_for_sources([{@storage_file, File.read!(@storage_file)}])
  end

  @spec violations_for_sources([{String.t(), String.t()}]) :: [violation()]
  def violations_for_sources(sources) do
    Enum.flat_map(sources, fn {file, source} ->
      file
      |> function_entries(source)
      |> Enum.reject(&safe_function?/1)
      |> Enum.map(fn %{name: name} ->
        %{file: file, function: name, reason: "tenant-scoped repo access without role wrapper"}
      end)
    end)
  end

  defp function_entries(file, source) do
    {_, functions} =
      source
      |> Code.string_to_quoted!(file: file)
      |> Macro.prewalk([], fn
        {kind, _, [{name, _, args}, body]} = node, acc when kind in [:def, :defp] ->
          args = args || []

          if ctx_function?(args) and repo_call?(body) do
            {node, [%{name: name, body: body} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    functions
  end

  defp ctx_function?(args) do
    Enum.any?(args, fn
      {name, _, _meta} when name == :ctx -> true
      _ -> false
    end)
  end

  defp safe_function?(%{name: name}) when name in @allowed_ctx_helpers, do: true

  defp safe_function?(%{body: body}) do
    wrapper_present?(body)
  end

  defp wrapper_present?(ast) do
    Macro.prewalk(ast, false, fn
      {name, _, _args} = node, _found when name in @safe_wrappers ->
        {node, true}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  defp repo_call?(ast) do
    Macro.prewalk(ast, false, fn
      {{:., _, [{:repo, _, _}, fun]}, _, _args} = node, _found
      when fun in [
             :all,
             :one,
             :get,
             :get_by,
             :insert,
             :insert!,
             :insert_all,
             :insert_or_update,
             :update,
             :delete,
             :delete_all,
             :transaction,
             :aggregate,
             :exists?
           ] ->
        {node, true}

      {{:., _, [{:__aliases__, _, [:SQL]}, fun]}, _, _args} = node, _found
      when fun in [:query, :query!] ->
        {node, true}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end
end
