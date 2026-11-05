defmodule Foresight.HTTP.Handlers.BankHandler do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error
  alias Foresight.HTTP.Auth
  alias Foresight.HTTP.ErrorTranslator
  alias Foresight.HTTP.HindsightWire
  alias Foresight.HTTP.RequestContext

  @spec list(Plug.Conn.t()) :: Plug.Conn.t()
  def list(conn) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, "default"),
           {:ok, banks} <- Foresight.list_banks(ctx) do
        json(conn, 200, HindsightWire.bank_list_response(banks))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec stats(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def stats(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, stats} <- Foresight.bank_stats(ctx, bank_id) do
        json(conn, 200, HindsightWire.bank_stats_response(stats))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec put(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      case parse_attrs(conn.body_params) do
        {:ok, attrs} ->
          with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
               {:ok, bank} <- Foresight.put_bank(ctx, bank_id, attrs) do
            json(conn, 200, HindsightWire.bank_profile_response(bank))
          else
            {:error, %Error{} = error} ->
              ErrorTranslator.send_error(conn, error)
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec patch(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def patch(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      case parse_attrs(conn.body_params) do
        {:ok, attrs} ->
          with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
               {:ok, bank} <- Foresight.patch_bank(ctx, bank_id, attrs) do
            json(conn, 200, HindsightWire.bank_profile_response(bank))
          else
            {:error, %Error{} = error} ->
              ErrorTranslator.send_error(conn, error)
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec put_profile(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_profile(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      case parse_disposition_update(conn.body_params) do
        {:ok, disposition} ->
          with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
               {:ok, bank} <- Foresight.update_bank_disposition(ctx, bank_id, disposition) do
            json(conn, 200, HindsightWire.bank_profile_response(bank))
          else
            {:error, %Error{} = error} ->
              ErrorTranslator.send_error(conn, error)
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec background(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def background(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      case parse_background_payload(conn.body_params) do
        {:ok, content} ->
          with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
               {:ok, result} <- Foresight.add_bank_background(ctx, bank_id, content) do
            json(conn, 200, HindsightWire.background_response(result))
          else
            {:error, %Error{} = error} ->
              ErrorTranslator.send_error(conn, error)
          end

        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec delete(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def delete(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <- Foresight.delete_bank(ctx, bank_id) do
        json(conn, 200, HindsightWire.delete_response(result, bank_id))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
  end

  @spec clear_memories(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def clear_memories(conn, bank_id) do
    with_authenticated(conn, fn conn ->
      with {:ok, ctx} <- RequestContext.resolve(conn, bank_id),
           {:ok, result} <-
             Foresight.clear_bank_memories(ctx, bank_id, fetch_query_params(conn).query_params) do
        json(conn, 200, HindsightWire.clear_memories_response(result))
      else
        {:error, %Error{} = error} ->
          ErrorTranslator.send_error(conn, error)
      end
    end)
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

  defp parse_attrs(%{} = attrs), do: {:ok, attrs}

  defp parse_attrs(_attrs) do
    {:error, Error.new(:invalid_request, %{message: "expected JSON object body"})}
  end

  defp parse_disposition_update(%{"disposition" => %{} = disposition}) do
    disposition
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      cond do
        key not in ~w(skepticism literalism empathy) ->
          {:halt,
           {:error,
            Error.new(:invalid_request, %{
              message: "disposition may only include skepticism, literalism, empathy"
            })}}

        is_integer(value) and value in 1..5 ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        true ->
          {:halt,
           {:error,
            Error.new(:invalid_request, %{
              message: "disposition values must be integers between 1 and 5"
            })}}
      end
    end)
  end

  defp parse_disposition_update(_body) do
    {:error,
     Error.new(:invalid_request, %{message: "profile update requires a disposition object"})}
  end

  defp parse_background_payload(%{"content" => content}) when is_binary(content) do
    trimmed = String.trim(content)

    if trimmed == "" do
      {:error, Error.new(:invalid_request, %{message: "background content must not be empty"})}
    else
      {:ok, trimmed}
    end
  end

  defp parse_background_payload(_body) do
    {:error, Error.new(:invalid_request, %{message: "background update requires string content"})}
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
