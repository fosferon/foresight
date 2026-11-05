defmodule Foresight.Webhooks.HttpcClient do
  @moduledoc false

  @behaviour Foresight.Webhooks.HTTPClient

  # Cap the stored response body so a hostile or broken receiver returning a huge
  # body cannot OOM the node or bloat the deliveries table.
  @max_response_bytes 64 * 1024
  @signature_header ~c"x-foresight-signature"

  @impl true
  def post(url, payload, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    headers = Keyword.get(opts, :headers, [])
    body = Jason.encode!(payload)

    signed_headers =
      case Keyword.get(opts, :sign_secret) do
        secret when is_binary(secret) and secret != "" ->
          signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
          headers ++ [{@signature_header, to_charlist("sha256=" <> signature)}]

        _ ->
          headers
      end

    request =
      {to_charlist(url), signed_headers ++ [{~c"content-type", ~c"application/json"}],
       ~c"application/json", body}

    httpc_options = [timeout: timeout_ms, autoredirect: false]

    case :httpc.request(:post, request, httpc_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, %{status: status, body: truncate(resp_body || "")}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp truncate(body) when byte_size(body) > @max_response_bytes,
    do: binary_part(body, 0, @max_response_bytes)

  defp truncate(body), do: body
end
