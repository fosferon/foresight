defmodule Foresight.MCP.Tools do
  @moduledoc false

  alias Foresight.Context
  alias Foresight.Error

  require Logger

  # Tools whose input_schema requires no bank_id. Kept in sync with @tools by a test.
  @bankless_tools ["list_banks"]

  @tools [
    %{
      name: "retain",
      description: "Store one memory item in a bank (async only when explicitly requested).",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        content: {:required, :string, description: "Memory content"},
        context: {:string, description: "Memory context"},
        type: {:string, description: "Memory type"},
        tags: {{:list, :string}, description: "Memory tags"},
        metadata: {{:map, :any}, description: "Arbitrary metadata"},
        async: {:boolean, description: "Async override"}
      }
    },
    %{
      name: "sync_retain",
      description: "Store one memory item synchronously in a bank.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        content: {:required, :string, description: "Memory content"},
        context: {:string, description: "Memory context"},
        type: {:string, description: "Memory type"},
        tags: {{:list, :string}, description: "Memory tags"},
        metadata: {{:map, :any}, description: "Arbitrary metadata"}
      }
    },
    %{
      name: "recall",
      description: "Recall relevant memories from a bank.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        query: {:required, :string, description: "Recall query"},
        budget: {:string, description: "Recall budget"},
        max_tokens: {:integer, description: "Token budget"},
        tags: {{:list, :string}, description: "Tag filter"},
        tags_match: {:string, description: "Tag matching mode"},
        tag_groups: {{:list, {:map, :any}}, description: "Compound tag groups"},
        include: {{:map, :any}, description: "Included companion surfaces"},
        trace: {:boolean, description: "Trace flag"},
        min_score:
          {:float, description: "Drop results whose score is below this non-negative number"}
      }
    },
    %{
      name: "reflect",
      description: "Run reflect against a bank.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        query: {:required, :string, description: "Reflect query"},
        budget: {:string, description: "Reflect budget"},
        max_tokens: {:integer, description: "Token budget"},
        tags: {{:list, :string}, description: "Tag filter"},
        include: {{:map, :any}, description: "Included companion surfaces"}
      }
    },
    %{
      name: "list_banks",
      description: "List banks.",
      input_schema: %{}
    },
    %{
      name: "create_bank",
      description: "Create or update a bank idempotently.",
      input_schema: %{
        bank_id: {:required, :string, description: "Bank id"},
        name: {:string, description: "Display name"},
        mission: {:string, description: "Bank mission"},
        disposition: {{:map, :any}, description: "Disposition map"}
      }
    },
    %{
      name: "list_memories",
      description: "List memories in a bank.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        limit: {:integer, description: "Page size"},
        offset: {:integer, description: "Page offset"},
        type: {:string, description: "Memory type"},
        tags: {{:list, :string}, description: "Tag filter"}
      }
    },
    %{
      name: "get_memory",
      description: "Fetch one memory by id.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        memory_id: {:required, :string, description: "Memory id"}
      }
    },
    %{
      name: "list_operations",
      description: "List async operations in a bank.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        limit: {:integer, description: "Page size"},
        offset: {:integer, description: "Page offset"},
        status: {:string, description: "Operation status"}
      }
    },
    %{
      name: "get_operation",
      description: "Fetch one async operation by id.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        operation_id: {:required, :string, description: "Operation id"}
      }
    },
    %{
      name: "list_tags",
      description: "List tags used in a bank.",
      input_schema: %{
        bank_id: {:required, :string, description: "Target bank id"},
        q: {:string, description: "Wildcard tag filter"},
        source: {:string, description: "Tag source"},
        limit: {:integer, description: "Page size"},
        offset: {:integer, description: "Page offset"}
      }
    }
  ]

  def definitions do
    Enum.map(@tools, fn tool ->
      Map.update!(tool, :input_schema, &tolerant_schema/1)
    end)
  end

  def call(tool_name, arguments) when is_binary(tool_name) and is_map(arguments) do
    args = arguments |> normalize() |> apply_aliases()
    warn_unknown_arguments(tool_name, args)

    with {:ok, ctx} <- context_from_args(args, tool_name) do
      dispatch(tool_name, ctx, args)
    end
  rescue
    # The Hermes server process holds every live MCP session, so a raise here would let
    # one client's malformed call disconnect every other client. Nothing escapes as an
    # exception; a bad call is always a structured error for that call alone.
    exception ->
      Logger.warning(
        "mcp tool #{tool_name} raised: " <> Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error,
       Error.new(:internal_error, %{
         operation: tool_name,
         message: Exception.message(exception)
       })}
  end

  # async defaults to FALSE: the async path needs Oban, and mcp can be enabled without it,
  # which left retain silently unable to complete. A caller that wants the queue asks for
  # it explicitly.
  #
  # This deliberately DIFFERS from the REST/file surface, which defaults to true — see
  # Foresight.Backend.Store.retain_files/3 for the reasoning on both sides. The divergence
  # tracks each surface's deployment constraint; both defaults are pinned by tests.
  defp dispatch("retain", %Context{} = ctx, args) do
    with {:ok, item} <- retain_item(args) do
      Foresight.retain(ctx, %{
        "items" => [item],
        "async" => Map.get(args, "async", false)
      })
    end
  end

  defp dispatch("sync_retain", %Context{} = ctx, args) do
    with {:ok, item} <- retain_item(args) do
      Foresight.retain(ctx, %{"items" => [item], "async" => false})
    end
  end

  defp dispatch("recall", %Context{} = ctx, args) do
    Foresight.recall(ctx, Map.drop(args, ["bank_id", "tenant_id", "role_name", "prefix"]))
  end

  defp dispatch("reflect", %Context{} = ctx, args) do
    Foresight.reflect(ctx, Map.drop(args, ["bank_id", "tenant_id", "role_name", "prefix"]))
  end

  defp dispatch("list_banks", %Context{} = ctx, _args) do
    with {:ok, banks} <- Foresight.list_banks(ctx) do
      {:ok, %{"banks" => banks}}
    end
  end

  defp dispatch("create_bank", %Context{} = ctx, %{"bank_id" => bank_id} = args) do
    attrs =
      args
      |> Map.take(["name", "mission", "disposition"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})

    Foresight.put_bank(ctx, bank_id, attrs)
  end

  defp dispatch("list_memories", %Context{} = ctx, args) do
    params = Map.drop(args, ["bank_id", "tenant_id", "role_name", "prefix"])
    Foresight.list_memories(ctx, params)
  end

  defp dispatch("get_memory", %Context{} = ctx, %{"memory_id" => memory_id}) do
    Foresight.get_memory(ctx, memory_id)
  end

  defp dispatch("list_operations", %Context{} = ctx, args) do
    params = Map.drop(args, ["bank_id", "tenant_id", "role_name", "prefix"])
    Foresight.list_operations(ctx, params)
  end

  defp dispatch("get_operation", %Context{} = ctx, %{"operation_id" => operation_id}) do
    Foresight.get_operation(ctx, operation_id)
  end

  defp dispatch("list_tags", %Context{} = ctx, args) do
    params = Map.drop(args, ["bank_id", "tenant_id", "role_name", "prefix"])
    Foresight.list_tags(ctx, params)
  end

  defp dispatch(other, _ctx, _args) do
    {:error, Error.new(:not_implemented, %{operation: other})}
  end

  # Hindsight's MCP retain names this flag async_processing (its changelog references the
  # parameter twice), and that consumer sends that name. Foresight reads "async". Accepted as an
  # alias so a client ported straight off Hindsight is not silently switched to synchronous
  # retain — for a batch that means running embedding and entity extraction inline against
  # the caller's request timeout, which trips a circuit breaker rather than enqueuing
  # .
  @argument_aliases %{"async_processing" => "async"}

  # Context keys are supplied by the transport/plug, not declared per tool.
  @context_arguments ~w(bank_id tenant_id role_name prefix)

  defp apply_aliases(args) do
    Enum.reduce(@argument_aliases, args, fn {from, to}, acc ->
      case Map.pop(acc, from) do
        {nil, acc} -> acc
        {value, popped} -> Map.put_new(popped, to, value)
      end
    end)
  end

  # An argument a tool does not declare is dropped by dispatch. Silently dropping it is the
  # real hazard: a rejected call is debuggable in seconds, a flag that vanishes is not. So
  # every unknown key is named in the log on the call that carried it.
  defp warn_unknown_arguments(tool_name, args) do
    case Enum.find(@tools, &(&1.name == tool_name)) do
      nil ->
        :ok

      tool ->
        declared =
          tool.input_schema
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Kernel.++(@context_arguments)

        case Map.keys(args) -- declared do
          [] ->
            :ok

          unknown ->
            Logger.warning(
              "mcp tool #{tool_name} received undeclared arguments #{inspect(Enum.sort(unknown))}; " <>
                "they were ignored"
            )
        end
    end
  end

  defp retain_item(%{"content" => content} = args) when is_binary(content) and content != "" do
    {:ok,
     %{
       "content" => content,
       "context" => Map.get(args, "context", "chat"),
       "type" => Map.get(args, "type", "experience"),
       "tags" => Map.get(args, "tags", []),
       "metadata" => Map.get(args, "metadata", %{})
     }}
  end

  defp retain_item(_args) do
    {:error, Error.new(:invalid_request, %{message: "content is required"})}
  end

  defp context_from_args(%{"bank_id" => bank_id} = args, _tool_name)
       when is_binary(bank_id) and bank_id != "" do
    {:ok, context(args, bank_id)}
  end

  # Tools whose input_schema requires no bank must not be gated on one here. list_banks is
  # the health check every consumer calls first, so gating it made a healthy service
  # report DOWN.
  defp context_from_args(args, tool_name) when tool_name in @bankless_tools do
    {:ok, context(args, nil)}
  end

  defp context_from_args(_args, _tool_name) do
    {:error, Error.new(:invalid_request, %{message: "bank_id is required"})}
  end

  defp context(args, bank_id) do
    %Context{
      tenant_id: Map.get(args, "tenant_id", "default"),
      mode: :mode_a,
      bank: bank_id,
      role_name: Map.get(args, "role_name"),
      prefix: Map.get(args, "prefix")
    }
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
      {normalized_key, normalize(item)}
    end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_binary(value) do
    cond do
      value in ["true", "false"] ->
        value == "true"

      Regex.match?(~r/^-?\d+$/, value) ->
        String.to_integer(value)

      Regex.match?(~r/^-?\d+\.\d+$/, value) ->
        String.to_float(value)

      String.starts_with?(value, "{") or String.starts_with?(value, "[") ->
        case Jason.decode(value) do
          {:ok, decoded} -> normalize(decoded)
          _ -> value
        end

      true ->
        value
    end
  end

  defp normalize(value), do: value

  defp tolerant_schema(schema) when is_map(schema) do
    Map.new(schema, fn {key, value} -> {key, tolerant_field(value)} end)
  end

  defp tolerant_field({:required, type, opts}) when is_list(opts),
    do: {:required, tolerant_type(type), opts}

  defp tolerant_field({:required, type}), do: {:required, tolerant_type(type)}

  defp tolerant_field({type, opts}) when is_list(opts), do: {tolerant_type(type), opts}
  defp tolerant_field(type), do: tolerant_type(type)

  defp tolerant_type(:string), do: :string
  defp tolerant_type(:any), do: :any
  defp tolerant_type(:integer), do: {:oneof, [:integer, :string]}
  defp tolerant_type(:float), do: {:oneof, [:float, :string]}
  defp tolerant_type(:boolean), do: {:oneof, [:boolean, :string]}

  defp tolerant_type({:list, item_type}),
    do: {:oneof, [{:list, tolerant_type(item_type)}, :string]}

  defp tolerant_type({:map, value_type}),
    do: {:oneof, [{:map, tolerant_type(value_type)}, :string]}

  defp tolerant_type(nested_schema) when is_map(nested_schema),
    do: {:oneof, [tolerant_schema(nested_schema), :string]}

  defp tolerant_type(other), do: other
end
