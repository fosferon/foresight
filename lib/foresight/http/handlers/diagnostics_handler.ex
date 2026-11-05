defmodule Foresight.HTTP.Handlers.DiagnosticsHandler do
  @moduledoc false

  import Plug.Conn

  alias Ecto.Adapters.SQL
  alias Foresight.Error
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.RequestContext
  alias Foresight.Tenancy

  @tenant_prefix_setting "foresight.tenant_prefix"

  @spec request_context(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def request_context(conn, bank_id) do
    config = conn.private |> Map.fetch!(:foresight_config)

    if diagnostics_enabled?(config) do
      case RequestContext.resolve(conn, bank_id) do
        {:ok, ctx} ->
          repo = repo_module(config)

          result =
            Tenancy.with_tenant_role(ctx, fn ->
              %{
                "tenant_id" => ctx.tenant_id,
                "mode" => Atom.to_string(ctx.mode),
                "bank" => ctx.bank,
                "prefix" => ctx.prefix,
                "role_name" => ctx.role_name,
                "db_role" => current_role(repo),
                "db_tenant_prefix" => current_tenant_prefix(repo)
              }
            end)

          case result do
            {:error, reason} ->
              ErrorTranslator.send_error(
                conn,
                Error.new(:service_unavailable, %{
                  message: "diagnostic role probe failed",
                  detail: inspect(reason)
                })
              )

            body ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(200, Jason.encode!(body))
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    else
      ErrorTranslator.send_error(conn, Error.new(:not_found))
    end
  end

  defp diagnostics_enabled?(config) do
    config
    |> get_in([:http, :diagnostics, :enabled])
    |> Kernel.==(true)
  end

  defp repo_module(config) do
    get_in(config, [:repo, :module]) || Foresight.Repo
  end

  defp current_role(repo) do
    case SQL.query!(repo, "SELECT current_role", []).rows do
      [[role_name]] -> role_name
      _ -> nil
    end
  end

  defp current_tenant_prefix(repo) do
    case SQL.query!(repo, "SELECT current_setting($1, true)", [@tenant_prefix_setting]).rows do
      [[prefix]] -> prefix
      _ -> nil
    end
  end
end
