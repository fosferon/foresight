defmodule Foresight.HTTP.Handlers.MigrationHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.RequestContext

  @spec migrate(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def migrate(conn, bank_id) do
    run(conn, bank_id, &Foresight.migrate_bank/2)
  end

  @spec probe(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def probe(conn, bank_id) do
    run(conn, bank_id, &Foresight.probe_bank_migration/2)
  end

  defp with_authenticated(conn, fun) do
    conn = Auth.authenticate(conn, auth_config(conn))

    if conn.halted do
      conn
    else
      fun.(conn)
    end
  end

  defp auth_config(conn) do
    conn.private
    |> Map.fetch!(:foresight_config)
  end

  defp parse_payload(%{} = payload), do: {:ok, payload}

  defp parse_payload(_payload) do
    {:error, Error.new(:invalid_request, %{message: "expected JSON object body"})}
  end

  defp run(conn, bank_id, fun) do
    with_authenticated(conn, fn conn ->
      case parse_payload(conn.body_params) do
        {:ok, payload} ->
          with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
               {:ok, result} <- fun.(ctx, payload) do
            json(conn, 200, result)
          else
            {:error, %Error{} = error} ->
              ErrorTranslator.send_error(conn, error)

            {:error, {:migration_diagnostics, diagnostics}} ->
              json(conn, 422, %{
                "error" => "migration_diagnostics",
                "detail" => to_wire(diagnostics)
              })
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  defp to_wire(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_atom(key) -> {Atom.to_string(key), to_wire(nested)}
      {key, nested} -> {key, to_wire(nested)}
    end)
  end

  defp to_wire(value) when is_list(value), do: Enum.map(value, &to_wire/1)
  defp to_wire(value) when is_boolean(value) or is_nil(value), do: value
  defp to_wire(value) when is_atom(value), do: Atom.to_string(value)
  defp to_wire(value), do: value

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
