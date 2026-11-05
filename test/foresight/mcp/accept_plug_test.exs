defmodule Foresight.MCP.AcceptPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Foresight.MCP.AcceptPlug

  test "normalize_accept_header appends event-stream for json-only clients" do
    conn =
      conn(:post, "/mcp")
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> AcceptPlug.normalize_accept_header()

    assert Plug.Conn.get_req_header(conn, "accept") == ["application/json, text/event-stream"]
  end

  test "normalize_accept_header defaults wildcard clients to json plus event-stream" do
    conn =
      conn(:post, "/mcp")
      |> Plug.Conn.put_req_header("accept", "*/*")
      |> AcceptPlug.normalize_accept_header()

    assert Plug.Conn.get_req_header(conn, "accept") == ["application/json, text/event-stream"]
  end

  test "inject_fixed_bank_id seeds bank_id into tool-call arguments" do
    message = %{
      "method" => "tools/call",
      "params" => %{
        "name" => "recall",
        "arguments" => %{"query" => "hello"}
      }
    }

    assert %{
             "params" => %{
               "arguments" => %{"query" => "hello", "bank_id" => "bank-a"},
               "_meta" => %{"fixed_bank_id" => "bank-a"}
             }
           } = AcceptPlug.inject_fixed_bank_id(message, "bank-a")
  end
end
