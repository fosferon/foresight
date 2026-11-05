defmodule Foresight.HTTP.Handlers.TemplateHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.RequestContext

  @spec schema(Plug.Conn.t()) :: Plug.Conn.t()
  def schema(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Foresight.BankTemplate.Schema.manifest()))
  end

  @spec export(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def export(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, manifest} <-
             Foresight.export_bank_template(ctx, bank_id, config: auth_config(conn)) do
        json(conn, 200, manifest)
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec import_manifest(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def import_manifest(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, manifest} <-
             parse_manifest(conn.body_params, fetch_query_params(conn).query_params),
           {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, response} <-
             Foresight.import_bank_template(ctx, bank_id, manifest, config: auth_config(conn)) do
        json(conn, 200, response)
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  defp parse_manifest(%{} = body, query_params) do
    dry_run =
      case Map.get(query_params, "dry_run", "false") do
        value when value in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Map.get(body, "version") do
      version when is_binary(version) ->
        {:ok, Map.put(body, "dry_run", dry_run)}

      _other ->
        {:error, Error.new(:invalid_request, %{message: "template manifest requires version"})}
    end
  end

  defp parse_manifest(_body, _query_params) do
    {:error, Error.new(:invalid_request, %{message: "expected JSON object body"})}
  end

  defp with_authenticated(conn, fun) do
    conn = Auth.authenticate(conn, auth_config(conn))

    if conn.halted do
      conn
    else
      fun.(conn)
    end
  end

  defp auth_config(conn), do: Map.fetch!(conn.private, :foresight_config)

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
