defmodule Foresight.Evals.HindsightBench do
  @moduledoc """
  The Hindsight arm of the matched-reader Foresight-vs-Hindsight scoreboard.

  This is the instrument that turns "we meet/exceed Hindsight" from an assertion into
  a measured number. It drives a LIVE Hindsight authority over its HTTP API through
  the exact same lifecycle the Foresight reflect arm runs — retain the same sessions,
  trigger consolidation, then reflect — so the ONLY variable is the memory
  architecture. Fairness is only real if that authority runs reflect AND consolidation
  on the SAME reader model as Foresight (gpt-oss:20b); see
  `scripts/start-hindsight-fixture-authority.sh` (it must export
  `HINDSIGHT_API_REFLECT_LLM_*` and `HINDSIGHT_API_CONSOLIDATION_LLM_*`, not only
  `HINDSIGHT_API_LLM_*`).

  Routes (verified against the Hindsight OpenAPI client):

    * `PUT    /v1/default/banks/{bank}`             — create/reset the bank
    * `POST   /v1/default/banks/{bank}/memories`    — retain (`async: false`)
    * `POST   /v1/default/banks/{bank}/consolidate` — trigger consolidation (async;
      poll `GET .../stats` `pending_consolidation` to 0)
    * `POST   /v1/default/banks/{bank}/reflect`     — reflect → `%{"text" => answer}`
    * `GET    /v1/default/banks/{bank}/stats`       — `pending_consolidation`, ...
    * `DELETE /v1/default/banks/{bank}`             — drop the bank between instances

  The public core (`retain_body/1`, `reflect_body/2`, `parse_reflect_answer/1`,
  `consolidation_pending?/1`, `client/2`) is pure and unit-tested; `generate/2` is the
  thin live-I/O orchestration exercised only in the matched-model `:ml`/`:eval` lane.
  """

  require Logger

  @type client :: %{base_url: String.t(), api_key: String.t()}

  @ingest_poll_ms 3_000
  @ingest_timeout_ms 900_000
  @consolidate_poll_ms 3_000
  @consolidate_timeout_ms 600_000
  # Hindsight retain runs synchronous LLM fact-extraction per session; on a slow
  # reasoning reader (gpt-oss:20b) a small haystack can exceed 5 min, so the retain/
  # reflect HTTP calls need generous headroom (Foresight's own retain only embeds).
  @http_timeout_ms 900_000
  @connect_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Pure core (unit-tested)
  # ---------------------------------------------------------------------------

  @doc "Build a Hindsight client from a base url (trailing slash trimmed) and api key."
  @spec client(String.t(), String.t()) :: client()
  def client(base_url, api_key) do
    %{base_url: String.trim_trailing(base_url, "/"), api_key: api_key}
  end

  @doc """
  Async retain body for a list of memory items. Content and every reflected field are
  sent byte-for-byte identical to Foresight; the ONLY transform is that non-string
  `metadata` VALUES are stringified, because Hindsight's retain schema rejects list/int
  metadata (Foresight carries `has_answer_turns` as an int list). Metadata is eval
  bookkeeping, not reflected content, so this keeps the head-to-head fair.

  `async: true` because Hindsight's synchronous retain does not return reliably over
  HTTP even when the ingestion completes; the async call returns instantly and the
  worker does the extract/embed/link work, which `generate/5` polls to completion.
  """
  @spec retain_body([map()]) :: map()
  def retain_body(memories) when is_list(memories) do
    %{"items" => Enum.map(memories, &sanitize_item/1), "async" => true}
  end

  defp sanitize_item(%{"metadata" => metadata} = item) when is_map(metadata) do
    %{item | "metadata" => Map.new(metadata, fn {k, v} -> {k, stringify_value(v)} end)}
  end

  defp sanitize_item(item), do: item

  defp stringify_value(v) when is_binary(v), do: v
  defp stringify_value(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp stringify_value(v), do: Jason.encode!(v)

  @doc "Reflect request body; `query_timestamp` is omitted entirely when nil."
  @spec reflect_body(String.t(), String.t() | nil) :: map()
  def reflect_body(query, nil), do: %{"query" => query}
  def reflect_body(query, ts), do: %{"query" => query, "query_timestamp" => ts}

  @doc "Extract the answer text from a reflect response; missing/nil → empty string."
  @spec parse_reflect_answer(map()) :: String.t()
  def parse_reflect_answer(response) when is_map(response) do
    to_string(response["text"] || "")
  end

  @doc "Whether a bank-stats payload reports outstanding retain/ingestion work."
  @spec operations_pending?(map()) :: boolean()
  def operations_pending?(stats) when is_map(stats) do
    (stats["pending_operations"] || 0) > 0
  end

  @doc "Whether a bank-stats payload reports outstanding consolidation work."
  @spec consolidation_pending?(map()) :: boolean()
  def consolidation_pending?(stats) when is_map(stats) do
    (stats["pending_consolidation"] || 0) > 0
  end

  # ---------------------------------------------------------------------------
  # Live orchestration (matched-model lane only)
  # ---------------------------------------------------------------------------

  @doc """
  Run one instance through the Hindsight arm on a fresh bank: reset → retain →
  consolidate (poll to completion) → reflect. Returns `{:ok, answer, meta}` where
  `meta` records `consolidated?` (did pending reach 0 before the timeout) and
  `retained` (item count) so the report can be honest about whether consolidation
  actually finished. Any HTTP failure short-circuits to `{:error, reason}`.
  """
  @spec generate(client(), String.t(), [map()], String.t(), String.t() | nil) ::
          {:ok, String.t(), map()} | {:error, term()}
  def generate(client, bank_id, memories, query, query_timestamp) do
    bank_path = "/v1/default/banks/#{bank_id}"

    with :ok <- reset_bank(client, bank_path),
         {:ok, retained} <- retain(client, bank_path, memories),
         {:ok, consolidated?} <- consolidate(client, bank_path),
         {:ok, response} <-
           request(client, :post, bank_path <> "/reflect", reflect_body(query, query_timestamp)) do
      {:ok, parse_reflect_answer(response), %{consolidated?: consolidated?, retained: retained}}
    end
  end

  defp reset_bank(client, bank_path) do
    # Delete is best-effort (bank may not exist yet); the PUT is what must succeed.
    _ = request(client, :delete, bank_path, nil)

    case request(client, :put, bank_path, %{
           "name" => "Foresight bench",
           "mission" => "Matched-model Foresight-vs-Hindsight reflect scoreboard."
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:bank_create, reason}}
    end
  end

  # Async retain returns instantly with an operation; the worker then does the
  # extract/embed/link ingestion. Poll pending_operations to 0 so consolidation and
  # reflect see the fully ingested graph (a timeout is surfaced honestly as an error).
  defp retain(client, bank_path, memories) do
    with {:ok, resp} <- request(client, :post, bank_path <> "/memories", retain_body(memories)),
         :ok <- poll_ingestion(client, bank_path, @ingest_timeout_ms) do
      {:ok, resp["items_count"] || length(memories)}
    else
      {:error, reason} -> {:error, {:retain, reason}}
      :timeout -> {:error, {:retain, :ingestion_timeout}}
    end
  end

  defp poll_ingestion(_client, _bank_path, remaining_ms) when remaining_ms <= 0, do: :timeout

  defp poll_ingestion(client, bank_path, remaining_ms) do
    case request(client, :get, bank_path <> "/stats", nil) do
      {:ok, stats} ->
        if operations_pending?(stats) do
          Process.sleep(@ingest_poll_ms)
          poll_ingestion(client, bank_path, remaining_ms - @ingest_poll_ms)
        else
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Trigger consolidation, then poll bank stats until pending_consolidation hits 0
  # or the timeout elapses. A timeout is reported honestly (consolidated? == false)
  # rather than silently proceeding as if the merge had finished.
  defp consolidate(client, bank_path) do
    case request(client, :post, bank_path <> "/consolidate", %{}) do
      {:ok, _} -> {:ok, poll_consolidation(client, bank_path, @consolidate_timeout_ms)}
      {:error, reason} -> {:error, {:consolidate, reason}}
    end
  end

  defp poll_consolidation(_client, _bank_path, remaining_ms) when remaining_ms <= 0, do: false

  defp poll_consolidation(client, bank_path, remaining_ms) do
    case request(client, :get, bank_path <> "/stats", nil) do
      {:ok, stats} ->
        if consolidation_pending?(stats) do
          Process.sleep(@consolidate_poll_ms)
          poll_consolidation(client, bank_path, remaining_ms - @consolidate_poll_ms)
        else
          true
        end

      {:error, _reason} ->
        # Stats unavailable: give consolidation a beat, then stop waiting rather
        # than loop forever. Honest outcome is "not confirmed consolidated".
        false
    end
  end

  defp request(client, method, path, body) do
    url = to_charlist(client.base_url <> path)
    headers = request_headers(client)

    request_spec =
      case body do
        nil -> {url, headers}
        payload -> {url, headers, ~c"application/json", Jason.encode!(payload)}
      end

    http_opts = [timeout: @http_timeout_ms, connect_timeout: @connect_timeout_ms]

    case :httpc.request(method, request_spec, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _r}, _h, raw}} when status in 200..299 ->
        {:ok, decode_body(raw)}

      {:ok, {{_v, status, _r}, _h, raw}} ->
        {:error, %{status: status, body: raw}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(""), do: %{}

  defp decode_body(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp request_headers(client) do
    [
      {~c"accept", ~c"application/json"},
      {~c"content-type", ~c"application/json"},
      {~c"authorization", ~c"Bearer " ++ String.to_charlist(client.api_key)}
    ]
  end
end
