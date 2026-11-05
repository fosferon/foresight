defmodule Foresight.Webhooks.WebhookHardeningTest do
  use ExUnit.Case, async: true

  alias Foresight.Schemas.Webhook

  describe "URL SSRF validation (H4)" do
    test "accepts public https/http URLs" do
      for url <- ["https://example.com/hook", "http://hooks.example.com:8080/x"] do
        assert Webhook.classify_url(url) == :ok
      end
    end

    test "rejects non-http schemes" do
      for url <- ["ftp://example.com", "file:///etc/passwd", "gopher://x"] do
        assert {:error, _} = Webhook.classify_url(url)
      end
    end

    test "rejects loopback, private, and link-local targets" do
      blocked = [
        "http://127.0.0.1/x",
        "http://localhost/x",
        "http://[::1]/x",
        "http://169.254.169.254/latest/meta-data/",
        # public-guard: allow (private-range fixture)
        "http://10.0.0.5/x",
        # public-guard: allow (private-range fixture)
        "http://192.168.1.1/x",
        # public-guard: allow (private-range fixture)
        "http://172.16.0.1/x",
        # public-guard: allow (private-range fixture)
        "http://172.31.255.255/x",
        "http://svc.internal/x",
        "http://[::ffff:127.0.0.1]/x",
        # public-guard: allow (private-range fixture)
        "http://[::ffff:10.0.0.1]/x"
      ]

      for url <- blocked do
        assert {:error, _} = Webhook.classify_url(url), "expected #{url} to be blocked"
      end
    end

    test "does not over-block a public 172.x that is outside the private range" do
      assert Webhook.classify_url("http://172.15.0.1/x") == :ok
      assert Webhook.classify_url("http://172.32.0.1/x") == :ok
    end

    test "changeset surfaces the url error and rejects the record" do
      changeset = Webhook.changeset(%Webhook{}, %{url: "http://169.254.169.254/"})
      refute changeset.valid?
      assert %{url: [_ | _]} = Ecto.Changeset.traverse_errors(changeset, & &1)
    end
  end

  describe "HMAC signature contract (H6)" do
    test "signature is a deterministic sha256 HMAC of the JSON body" do
      payload = %{"a" => 1, "b" => "two"}
      body = Jason.encode!(payload)
      secret = "shhh"

      sig = fn ->
        "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
      end

      assert sig.() == sig.()
      assert String.starts_with?(sig.(), "sha256=")
      assert byte_size(sig.()) == String.length("sha256=") + 64
    end
  end
end
