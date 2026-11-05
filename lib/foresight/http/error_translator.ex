defmodule Foresight.HTTP.ErrorTranslator do
  @moduledoc false

  import Plug.Conn

  alias Foresight.Error

  # NOT `alias LlmCore.LLM.Error` + `%LlmError{}`. llm_core is an optional
  # dependency, and a struct literal is a COMPILE-TIME reference — it made the whole
  # HTTP surface, and therefore the whole library, fail to compile for any consumer who
  # did not install llm_core. Matching on the struct's module at runtime keeps the exact
  # same behaviour without binding compilation to a dependency that may not be there.
  @llm_error_module :"Elixir.LlmCore.LLM.Error"

  @spec send_error(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def send_error(conn, %Error{} = error) do
    body =
      %{
        error: Atom.to_string(error.reason),
        detail: error.detail
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_for(error.reason), Jason.encode!(body))
  end

  def send_error(conn, %{__struct__: @llm_error_module, type: _} = error) do
    body = %{
      error: Atom.to_string(error.type),
      detail: llm_error_detail(error)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_for_llm_error(error.type), Jason.encode!(body))
  end

  def send_error(conn, {:error, error}), do: send_error(conn, error)

  def send_error(conn, _error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(500, Jason.encode!(%{error: "internal_error"}))
  end

  @spec status_for(atom()) :: pos_integer()
  def status_for(:invalid_request), do: 400
  def status_for(:unauthorized), do: 401
  def status_for(:not_found), do: 404
  def status_for(:gone), do: 410
  def status_for(:service_unavailable), do: 503
  # Producers across the codebase emit :unavailable (webhooks, async queues,
  # workers). Map it to 503 so load balancers and clients retry instead of treating
  # a transient backend outage as a permanent 500.
  def status_for(:unavailable), do: 503
  def status_for(:timeout), do: 504
  def status_for(:not_implemented), do: 501
  def status_for(_reason), do: 500

  defp status_for_llm_error(:connection), do: 503
  defp status_for_llm_error(:authentication), do: 502
  defp status_for_llm_error(:rate_limit), do: 503
  defp status_for_llm_error(:timeout), do: 504
  defp status_for_llm_error(:provider_error), do: 502

  defp llm_error_detail(%{__struct__: @llm_error_module} = error) do
    base =
      %{
        "message" => error.message,
        "provider" => error.provider && Atom.to_string(error.provider)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case error.details do
      details when is_map(details) -> Map.merge(base, redact_details(details))
      nil -> base
      details -> Map.put(base, "details", details)
    end
  end

  # Never serialize server internals (stacktraces, exception structs) to clients —
  # they leak module paths, line numbers, and local state. Logging keeps them.
  @sensitive_detail_keys [:stacktrace, "stacktrace", :__exception__, "__exception__"]

  defp redact_details(details) when is_map(details) do
    details
    |> Map.drop(@sensitive_detail_keys)
    |> Map.new(fn {key, value} -> {key, redact_value(value)} end)
  end

  defp redact_value(value) when is_map(value), do: redact_details(value)
  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  defp redact_value(value), do: value
end
