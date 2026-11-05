defmodule Foresight.TenantScope do
  @moduledoc false

  alias Foresight.Context
  alias Foresight.Error

  @spec snapshot(Context.t()) :: map()
  def snapshot(%Context{} = ctx) do
    %{
      "tenant_ids" => List.wrap(present_value(ctx.tenant_id)),
      "roles" => List.wrap(present_value(ctx.role_name)),
      "prefixes" => List.wrap(present_value(ctx.prefix))
    }
  end

  @spec authorized_snapshot(Context.t(), map() | nil) :: {:ok, map()} | {:error, Error.t()}
  def authorized_snapshot(%Context{} = ctx, nil), do: {:ok, snapshot(ctx)}

  def authorized_snapshot(%Context{} = ctx, scope) when is_map(scope) do
    with :ok <- validate_context(ctx, scope) do
      {:ok, normalize_scope(scope)}
    end
  end

  def authorized_snapshot(%Context{}, _scope) do
    {:error,
     Error.new(:invalid_request, %{
       message: "tenant_scope must be a map when provided"
     })}
  end

  @spec validate_context(Context.t(), map() | nil) :: :ok | {:error, Error.t()}
  def validate_context(%Context{}, nil), do: :ok

  def validate_context(%Context{} = ctx, scope) when is_map(scope) do
    with :ok <-
           validate_allowed_value(
             ctx.tenant_id,
             scope["tenant_ids"] || scope[:tenant_ids],
             "tenant"
           ),
         :ok <- validate_allowed_value(ctx.role_name, scope["roles"] || scope[:roles], "role"),
         :ok <-
           validate_allowed_value(ctx.prefix, scope["prefixes"] || scope[:prefixes], "prefix") do
      :ok
    end
  end

  defp validate_allowed_value(nil, _allowed, _kind), do: :ok
  defp validate_allowed_value(_value, nil, _kind), do: :ok
  defp validate_allowed_value(_value, [], kind), do: unauthorized_scope_claim(kind)

  defp validate_allowed_value(value, allowed, kind) when is_list(allowed) do
    if value in allowed do
      :ok
    else
      unauthorized_scope_claim(kind)
    end
  end

  defp unauthorized_scope_claim(kind) do
    {:error,
     Error.new(:unauthorized, %{
       message: "requested #{kind} scope is not allowed for this job"
     })}
  end

  defp normalize_scope(scope) do
    %{
      "tenant_ids" => normalize_scope_values(scope["tenant_ids"] || scope[:tenant_ids]),
      "roles" => normalize_scope_values(scope["roles"] || scope[:roles]),
      "prefixes" => normalize_scope_values(scope["prefixes"] || scope[:prefixes])
    }
  end

  defp normalize_scope_values(nil), do: nil
  defp normalize_scope_values(values) when is_list(values), do: values
  defp normalize_scope_values(value), do: [value]

  defp present_value(nil), do: nil
  defp present_value(""), do: nil
  defp present_value(value), do: value
end
