defmodule Foresight.UsageTest do
  use ExUnit.Case, async: true

  alias Foresight.Usage

  test "recording without an open ledger is a no-op and drain returns nothing" do
    assert :ok = Usage.record(%{"kind" => "llm", "input_tokens" => 5})
    assert Usage.drain() == []
    assert Usage.report([]) == nil
  end

  test "a ledger collects calls in order and reports totals over successful calls" do
    Usage.start()

    Usage.record(%{
      "kind" => "llm",
      "role" => "extract",
      "input_tokens" => 10,
      "output_tokens" => 4
    })

    Usage.record(%{
      "kind" => "embedding",
      "provider" => "remote",
      "input_tokens" => 7,
      "total_tokens" => 7
    })

    Usage.record(%{"kind" => "llm", "role" => "extract", "status" => "error"})

    entries = Usage.drain()
    assert Enum.map(entries, & &1["kind"]) == ["llm", "embedding", "llm"]
    assert Usage.drain() == []

    report = Usage.report(entries)
    assert report["input_tokens"] == 17
    assert report["output_tokens"] == 4
    assert report["total_tokens"] == 7
    assert report["failed_calls"] == 1
    assert length(report["calls"]) == 3
  end

  test "llm_entry reads llm_core response usage, provider, model and request id" do
    response = %{
      provider: :openai,
      model: "gpt-x",
      usage: %{prompt_tokens: 12, completion_tokens: 3, total_tokens: 15},
      metadata: %{request_id: "req-1"},
      raw: nil
    }

    assert %{
             "kind" => "llm",
             "role" => "extract",
             "provider" => "openai",
             "model" => "gpt-x",
             "input_tokens" => 12,
             "output_tokens" => 3,
             "total_tokens" => 15,
             "request_id" => "req-1",
             "status" => "ok"
           } = Usage.llm_entry(response, :extract)

    assert %{"status" => "error", "provider" => "ollama", "total_tokens" => 0} =
             Usage.llm_error_entry(:ollama, :consolidate)
  end
end
