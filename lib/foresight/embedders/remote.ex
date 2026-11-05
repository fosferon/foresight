defmodule Foresight.Embedders.Remote do
  @moduledoc """
  OpenAI-compatible remote embedder: POSTs to `<base_url>/embeddings` (LM Studio,
  vLLM, Ollama's OpenAI shim, or a cloud provider). Mirrors the LLM local↔cloud
  fork (Foresight.LLMs.LlmCore) for embeddings, so a single endpoint can serve
  both the reader and the embedder in dev, and a cloud provider can serve both in
  production — closing the "embeddings are local-only" gap.

  ## Configuration

  Connection config is operator-provided via application env (typically wired from
  the profile builder), and may be overridden per call:

      config :foresight, Foresight.Embedders.Remote,
        base_url: System.get_env("FORESIGHT_EMBED_BASE_URL"),
        api_key: System.get_env("FORESIGHT_EMBED_API_KEY"),
        model: System.get_env("FORESIGHT_EMBED_MODEL"),
        dimension: 384,
        timeout_ms: 30_000

  `base_url` must include the version prefix (e.g. `http://127.0.0.1:1234/v1`),
  exactly like the LLM fork. Per-call opts from `EmbeddingProfile.embedder_opts/1`
  (`model_id`, `embedding_dim`) override `model`/`dimension`.

  ## Dimension guard

  `dimension` is authoritative: every returned vector is checked against it and a
  mismatch is an error, never a silently-stored wrong-dim vector. This keeps a
  misconfigured or drifting provider from poisoning a bank whose profile is pinned
  to one dimension.
  """

  @behaviour Foresight.Embedder

  @default_timeout_ms 30_000
  @embeddings_path "/embeddings"

  @impl true
  def dimension(opts) do
    case resolve_dimension(config(opts)) do
      dim when is_integer(dim) and dim > 0 -> {:ok, dim}
      _ -> {:error, :remote_embedder_dimension_not_configured}
    end
  end

  @impl true
  def embed(text, opts) when is_binary(text) do
    case embed_many([text], opts) do
      {:ok, [vector]} -> {:ok, vector}
      {:ok, _other} -> {:error, :remote_embedder_unexpected_count}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def embed_many([], _opts), do: {:ok, []}

  def embed_many(texts, opts) when is_list(texts) do
    cfg = config(opts)

    with {:ok, base_url} <- fetch(cfg, :base_url, :remote_embedder_base_url_missing),
         {:ok, model} <- fetch(cfg, :model, :remote_embedder_model_missing),
         {:ok, raw_body} <- post_embeddings(base_url, model, texts, cfg),
         {:ok, decoded} <- decode(raw_body),
         {:ok, vectors} <- extract_vectors(decoded, length(texts)),
         :ok <- verify_dimensions(vectors, resolve_dimension(cfg)) do
      record_usage(decoded, model, base_url, length(texts), "ok")
      {:ok, vectors}
    else
      {:error, _reason} = error ->
        record_usage(%{}, cfg[:model], cfg[:base_url], length(texts), "error")
        error
    end
  end

  # Every chargeable call lands in the operation's usage ledger (Foresight.Usage;
  # a no-op when none is open): the provider's reported token count, the model
  # that answered, the endpoint host and the request id, so a consumer can bill
  # pass-through-at-cost and reconcile against the provider's own records.
  defp record_usage(decoded, model, base_url, text_count, status) do
    usage = Map.get(decoded, "usage") || %{}

    Foresight.Usage.record(%{
      "kind" => "embedding",
      "provider" => "remote",
      "endpoint" => endpoint_host(base_url),
      "model" => Map.get(decoded, "model") || model,
      "input_tokens" => integer_or_zero(usage["prompt_tokens"]),
      "output_tokens" => 0,
      "total_tokens" => integer_or_zero(usage["total_tokens"] || usage["prompt_tokens"]),
      "units" => text_count,
      "request_id" => if(is_binary(decoded["id"]), do: decoded["id"]),
      "status" => status
    })
  end

  defp endpoint_host(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp endpoint_host(_base_url), do: nil

  defp integer_or_zero(value) when is_integer(value), do: value
  defp integer_or_zero(_value), do: 0

  # --- config -----------------------------------------------------------------

  defp config(opts) do
    app = Application.get_env(:foresight, __MODULE__, [])

    %{
      base_url: opts[:base_url] || app[:base_url],
      api_key: opts[:api_key] || app[:api_key],
      # EmbeddingProfile.embedder_opts/1 supplies :model_id; a direct caller may
      # pass :model. Either identifies the served model.
      model: opts[:model] || opts[:model_id] || app[:model],
      dimension: opts[:dimension] || opts[:embedding_dim] || app[:dimension],
      timeout_ms: opts[:timeout_ms] || app[:timeout_ms] || @default_timeout_ms,
      # Injectable transport for tests: a 1-arity fun taking a request map
      # %{url, headers, body, timeout_ms} → {:ok, %{status, body}} | {:error, term}.
      http_post: opts[:http_post] || app[:http_post]
    }
  end

  defp resolve_dimension(%{dimension: dim}) when is_integer(dim) and dim > 0, do: dim

  defp resolve_dimension(%{dimension: dim}) when is_binary(dim) do
    case Integer.parse(dim) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp resolve_dimension(_cfg), do: nil

  defp fetch(cfg, key, error) do
    case Map.get(cfg, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  # --- transport --------------------------------------------------------------

  defp post_embeddings(base_url, model, texts, cfg) do
    url = String.trim_trailing(base_url, "/") <> @embeddings_path
    body = Jason.encode!(%{"model" => model, "input" => texts})
    headers = auth_headers(cfg[:api_key])

    request = %{url: url, headers: headers, body: body, timeout_ms: cfg.timeout_ms}

    case do_post(cfg[:http_post], request) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:remote_embedder_http_error, status, truncate(resp_body)}}

      {:error, reason} ->
        {:error, {:remote_embedder_transport_error, reason}}
    end
  end

  defp do_post(http_post, request) when is_function(http_post, 1), do: http_post.(request)

  defp do_post(_none, %{url: url, headers: headers, body: body, timeout_ms: timeout_ms}) do
    httpc_headers =
      Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    httpc_request =
      {to_charlist(url), httpc_headers, ~c"application/json", body}

    case :httpc.request(:post, httpc_request, [timeout: timeout_ms, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, %{status: status, body: resp_body || ""}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers(api_key) when is_binary(api_key) and api_key != "",
    do: [{"authorization", "Bearer " <> api_key}]

  defp auth_headers(_api_key), do: []

  # --- response parsing -------------------------------------------------------

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:remote_embedder_invalid_json, truncate(raw_body)}}
    end
  end

  # OpenAI embeddings response: %{"data" => [%{"embedding" => [...], "index" => n}, ...]}.
  # Order by `index` (spec permits out-of-order) and require one vector per input.
  defp extract_vectors(%{"data" => data}, expected_count) when is_list(data) do
    vectors =
      data
      |> Enum.sort_by(&index_of/1)
      |> Enum.map(&embedding_of/1)

    cond do
      Enum.any?(vectors, &(&1 == :error)) ->
        {:error, :remote_embedder_malformed_data}

      length(vectors) != expected_count ->
        {:error, {:remote_embedder_count_mismatch, expected_count, length(vectors)}}

      true ->
        {:ok, vectors}
    end
  end

  defp extract_vectors(_decoded, _expected_count), do: {:error, :remote_embedder_no_data}

  defp index_of(%{"index" => index}) when is_integer(index), do: index
  defp index_of(_entry), do: 0

  defp embedding_of(%{"embedding" => embedding}) when is_list(embedding) do
    if Enum.all?(embedding, &is_number/1), do: embedding, else: :error
  end

  defp embedding_of(_entry), do: :error

  defp verify_dimensions(_vectors, nil), do: {:error, :remote_embedder_dimension_not_configured}

  defp verify_dimensions(vectors, dim) do
    case Enum.find(vectors, &(length(&1) != dim)) do
      nil -> :ok
      mismatched -> {:error, {:remote_embedder_dimension_mismatch, dim, length(mismatched)}}
    end
  end

  defp truncate(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp truncate(body), do: inspect(body)
end
