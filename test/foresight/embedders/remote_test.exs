defmodule Foresight.Embedders.RemoteTest do
  @moduledoc """
  Unit tests for the OpenAI-compatible remote embedder. Uses an
  injected transport (opts[:http_post]) so no network is touched, and asserts the
  behaviour contract plus the guards that keep a misbehaving provider from
  poisoning a bank: dimension mismatch, count mismatch, out-of-order data,
  non-2xx, and malformed JSON.
  """
  use ExUnit.Case, async: true

  alias Foresight.Embedders.Remote

  @base "http://localhost:1234/v1"
  @dim 4

  defp ok_body(vectors) do
    data =
      vectors
      |> Enum.with_index()
      |> Enum.map(fn {vec, i} -> %{"embedding" => vec, "index" => i} end)

    Jason.encode!(%{"data" => data, "model" => "test-model"})
  end

  defp transport(fun), do: fn request -> fun.(request) end

  defp base_opts(http_post) do
    [
      base_url: @base,
      model: "test-model",
      dimension: @dim,
      http_post: http_post
    ]
  end

  test "embed_many records the provider's reported usage in an open ledger" do
    body =
      Jason.encode!(%{
        "id" => "emb-req-9",
        "model" => "served-model",
        "data" => [
          %{"embedding" => [1.0, 0.0, 0.0, 0.0], "index" => 0},
          %{"embedding" => [0.0, 1.0, 0.0, 0.0], "index" => 1}
        ],
        "usage" => %{"prompt_tokens" => 11, "total_tokens" => 11}
      })

    http_post = transport(fn _request -> {:ok, %{status: 200, body: body}} end)

    Foresight.Usage.start()
    assert {:ok, [_, _]} = Remote.embed_many(["a", "b"], base_opts(http_post))

    assert [entry] = Foresight.Usage.drain()

    assert %{
             "kind" => "embedding",
             "provider" => "remote",
             "endpoint" => "localhost",
             "model" => "served-model",
             "input_tokens" => 11,
             "output_tokens" => 0,
             "total_tokens" => 11,
             "units" => 2,
             "request_id" => "emb-req-9",
             "status" => "ok"
           } = entry
  end

  test "a failed embedding call is recorded as an error entry, not dropped" do
    http_post = transport(fn _request -> {:ok, %{status: 503, body: "down"}} end)

    Foresight.Usage.start()

    assert {:error, {:remote_embedder_http_error, 503, _}} =
             Remote.embed_many(["a"], base_opts(http_post))

    assert [%{"kind" => "embedding", "status" => "error", "units" => 1, "total_tokens" => 0}] =
             Foresight.Usage.drain()
  end

  test "embed returns a single vector and posts an OpenAI-shaped request to /embeddings" do
    parent = self()

    http_post =
      transport(fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 200, body: ok_body([[0.1, 0.2, 0.3, 0.4]])}}
      end)

    assert {:ok, [0.1, 0.2, 0.3, 0.4]} = Remote.embed("hello", base_opts(http_post))

    assert_received {:request, request}
    assert request.url == "http://localhost:1234/v1/embeddings"
    assert %{"model" => "test-model", "input" => ["hello"]} = Jason.decode!(request.body)
  end

  test "embed_many preserves input order even when the provider returns data out of order" do
    http_post =
      transport(fn _request ->
        # Return the two vectors with indices reversed.
        body =
          Jason.encode!(%{
            "data" => [
              %{"embedding" => [2, 2, 2, 2], "index" => 1},
              %{"embedding" => [1, 1, 1, 1], "index" => 0}
            ]
          })

        {:ok, %{status: 200, body: body}}
      end)

    assert {:ok, [[1, 1, 1, 1], [2, 2, 2, 2]]} =
             Remote.embed_many(["a", "b"], base_opts(http_post))
  end

  test "embed_many on an empty list short-circuits without calling the transport" do
    http_post = transport(fn _ -> flunk("transport must not be called for []") end)
    assert {:ok, []} = Remote.embed_many([], base_opts(http_post))
  end

  test "a wrong-dimension vector is rejected, not silently stored" do
    http_post =
      transport(fn _ -> {:ok, %{status: 200, body: ok_body([[0.1, 0.2, 0.3]])}} end)

    assert {:error, {:remote_embedder_dimension_mismatch, 4, 3}} =
             Remote.embed("hi", base_opts(http_post))
  end

  test "a count mismatch (fewer vectors than inputs) is an error" do
    http_post =
      transport(fn _ -> {:ok, %{status: 200, body: ok_body([[1, 1, 1, 1]])}} end)

    assert {:error, {:remote_embedder_count_mismatch, 2, 1}} =
             Remote.embed_many(["a", "b"], base_opts(http_post))
  end

  test "a non-2xx response surfaces the status and truncated body" do
    http_post =
      transport(fn _ -> {:ok, %{status: 503, body: "upstream unavailable"}} end)

    assert {:error, {:remote_embedder_http_error, 503, "upstream unavailable"}} =
             Remote.embed("hi", base_opts(http_post))
  end

  test "malformed JSON is an error, not a crash" do
    http_post = transport(fn _ -> {:ok, %{status: 200, body: "not json"}} end)
    assert {:error, {:remote_embedder_invalid_json, _}} = Remote.embed("hi", base_opts(http_post))
  end

  test "a transport error is wrapped" do
    http_post = transport(fn _ -> {:error, :timeout} end)

    assert {:error, {:remote_embedder_transport_error, :timeout}} =
             Remote.embed("hi", base_opts(http_post))
  end

  test "missing base_url or model is a clear config error" do
    http_post = transport(fn _ -> flunk("must not reach transport") end)

    assert {:error, :remote_embedder_base_url_missing} =
             Remote.embed("hi", model: "m", dimension: @dim, http_post: http_post)

    assert {:error, :remote_embedder_model_missing} =
             Remote.embed("hi", base_url: @base, dimension: @dim, http_post: http_post)
  end

  test "dimension/1 reports the configured dimension and errors when unset" do
    assert {:ok, 1024} = Remote.dimension(embedding_dim: 1024)
    assert {:ok, 1536} = Remote.dimension(dimension: 1536)
    assert {:error, :remote_embedder_dimension_not_configured} = Remote.dimension([])
  end

  test "auth header is sent when an api_key is configured" do
    parent = self()

    http_post =
      transport(fn request ->
        send(parent, {:headers, request.headers})
        {:ok, %{status: 200, body: ok_body([[1, 1, 1, 1]])}}
      end)

    assert {:ok, _} = Remote.embed("hi", base_opts(http_post) ++ [api_key: "secret-key"])
    assert_received {:headers, headers}
    assert {"authorization", "Bearer secret-key"} in headers
  end
end
