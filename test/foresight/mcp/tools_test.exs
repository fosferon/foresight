defmodule Foresight.MCP.ToolsTest do
  use ExUnit.Case, async: false

  alias Foresight.MCP.Tools

  setup do
    original_backend = Application.get_env(:foresight, :backend)
    Application.put_env(:foresight, :backend, Foresight.TestSupport.NoopBackend)

    on_exit(fn ->
      if original_backend do
        Application.put_env(:foresight, :backend, original_backend)
      else
        Application.delete_env(:foresight, :backend)
      end
    end)
  end

  test "sync_retain maps onto the existing retain engine call" do
    assert {:ok, %{op: :retain, payload: payload}} =
             Tools.call("sync_retain", %{
               "bank_id" => "bank-a",
               "content" => "hello",
               "context" => "chat",
               "tags" => ["alpha"],
               "metadata" => %{"source" => "mcp"}
             })

    assert payload["async"] == false

    assert payload["items"] == [
             %{
               "content" => "hello",
               "context" => "chat",
               "type" => "experience",
               "tags" => ["alpha"],
               "metadata" => %{"source" => "mcp"}
             }
           ]
  end

  test "definitions expose the exact core MCP tool inventory" do
    assert Enum.map(Tools.definitions(), & &1.name) == [
             "retain",
             "sync_retain",
             "recall",
             "reflect",
             "list_banks",
             "create_bank",
             "list_memories",
             "get_memory",
             "list_operations",
             "get_operation",
             "list_tags"
           ]
  end

  test "retain uses the existing retain engine call, synchronously by default" do
    assert {:ok, %{op: :retain, payload: payload}} =
             Tools.call("retain", %{
               "bank_id" => "bank-a",
               "content" => "hello",
               "tags" => ["alpha"]
             })

    # Was async-by-default until a later fix; the async path needs Oban, which mcp does not
    # require, so the default could never complete for an mcp-without-oban deployment.
    assert payload["async"] == false

    assert payload["items"] == [
             %{
               "content" => "hello",
               "context" => "chat",
               "type" => "experience",
               "tags" => ["alpha"],
               "metadata" => %{}
             }
           ]
  end

  test "recall tolerates stringified scalar and object arguments" do
    assert {:ok, %{op: :recall, query: query}} =
             Tools.call("recall", %{
               "bank_id" => "bank-a",
               "query" => "hello",
               "max_tokens" => "25",
               "trace" => "true",
               "min_score" => "0.4",
               "include" => "{\"chunks\":true}"
             })

    refute Map.has_key?(query, "bank_id")
    assert query["max_tokens"] == 25
    assert query["trace"] == true
    assert query["min_score"] == 0.4
    assert query["include"] == %{"chunks" => true}
  end

  test "list_banks wraps the existing engine call in an MCP-friendly payload" do
    assert {:ok, %{"banks" => []}} = Tools.call("list_banks", %{"bank_id" => "ignored"})
  end

  test "reflect routes to the existing reflect engine call" do
    assert {:ok, %{op: :reflect, query: query}} =
             Tools.call("reflect", %{
               "bank_id" => "bank-a",
               "query" => "hello",
               "max_tokens" => "25"
             })

    assert query == %{"query" => "hello", "max_tokens" => 25}
  end

  test "create_bank routes to the existing bank put call" do
    assert {:ok,
            %{
              id: "bank-a",
              attrs: %{
                "name" => "Bank A",
                "mission" => "Remember useful things",
                "disposition" => %{"skepticism" => 3}
              }
            }} =
             Tools.call("create_bank", %{
               "bank_id" => "bank-a",
               "name" => "Bank A",
               "mission" => "Remember useful things",
               "disposition" => %{"skepticism" => 3}
             })
  end

  test "list_memories routes to the existing memory listing read" do
    assert {:ok,
            %{
              op: :list_memories,
              params: %{"limit" => 10, "type" => "observation", "tags" => ["alpha"]}
            }} =
             Tools.call("list_memories", %{
               "bank_id" => "bank-a",
               "limit" => "10",
               "type" => "observation",
               "tags" => ["alpha"]
             })
  end

  test "get_memory routes to the existing memory read" do
    assert {:ok, %{op: :get_memory, id: "memory-1"}} =
             Tools.call("get_memory", %{"bank_id" => "bank-a", "memory_id" => "memory-1"})
  end

  test "list_tags routes to the existing tag discovery read" do
    assert {:ok, %{op: :list_tags, params: %{"limit" => 10}}} =
             Tools.call("list_tags", %{"bank_id" => "bank-a", "limit" => "10"})
  end

  test "get_operation routes to the existing operation read" do
    assert {:ok, %{op: :get_operation, id: "op-1"}} =
             Tools.call("get_operation", %{"bank_id" => "bank-a", "operation_id" => "op-1"})
  end

  test "list_operations routes to the existing operation listing read" do
    assert {:ok, %{op: :list_operations, params: %{"limit" => 10, "status" => "queued"}}} =
             Tools.call("list_operations", %{
               "bank_id" => "bank-a",
               "limit" => "10",
               "status" => "queued"
             })
  end

  # list_banks declares no required arguments, and it is the health check
  # every MCP consumer calls first. Requiring bank_id in the shared context builder made
  # a healthy service report DOWN.
  test "list_banks succeeds with no arguments, as its schema promises" do
    assert Enum.find(Tools.definitions(), &(&1.name == "list_banks")).input_schema
           |> Map.get(:required, [])
           |> Enum.empty?()

    assert {:ok, %{"banks" => []}} = Tools.call("list_banks", %{})
  end

  test "every tool whose schema omits bank_id is callable without one" do
    # Guards the hand-maintained @bankless_tools list against drift from @tools: if a new
    # bank-less tool is added to the schema and not to that list, it becomes unreachable.
    for tool <- Tools.definitions(),
        not match?({:required, _type, _opts}, Map.get(tool.input_schema, :bank_id)) do
      refute match?(
               {:error, %Foresight.Error{detail: %{message: "bank_id is required"}}},
               Tools.call(tool.name, %{})
             ),
             "#{tool.name} declares no required bank_id but is gated on one"
    end
  end

  test "tools that do need a bank still reject a missing bank_id" do
    assert {:error, %Foresight.Error{reason: :invalid_request}} =
             Tools.call("recall", %{"query" => "anything"})
  end

  # a bad call must not be able to take the server down, because the Hermes
  # server process holds every live session.
  test "a missing required argument is a structured error, never a raise" do
    assert {:error, %Foresight.Error{reason: reason}} =
             Tools.call("retain", %{"bank_id" => "bank-a"})

    assert reason in [:invalid_request, :not_implemented]
  end

  test "an unknown tool is a structured error" do
    assert {:error, %Foresight.Error{reason: :not_implemented}} =
             Tools.call("no_such_tool", %{"bank_id" => "bank-a"})
  end

  # MCP defaulted retain to async, which silently requires Oban. A caller
  # running MCP without Oban got a retain that could never complete.
  test "retain does not default to the async path that requires Oban" do
    assert {:ok, %{op: :retain, payload: payload}} =
             Tools.call("retain", %{"bank_id" => "bank-a", "content" => "hello"})

    assert payload["async"] == false
  end

  # Note: Hindsight's MCP retain names this flag async_processing and that consumer sends that
  # name. Foresight reads "async", so the flag was silently dropped — and after that fix
  # made MCP retain sync-by-default, a batch that expected queuing would instead run
  # embedding and entity extraction inline against the caller's timeout.
  test "accepts async_processing as an alias for async" do
    assert {:ok, %{op: :retain, payload: payload}} =
             Tools.call("retain", %{
               "bank_id" => "bank-a",
               "content" => "hello",
               "async_processing" => true
             })

    assert payload["async"] == true
  end

  test "an explicit async wins over the alias rather than being overwritten by it" do
    assert {:ok, %{op: :retain, payload: payload}} =
             Tools.call("retain", %{
               "bank_id" => "bank-a",
               "content" => "hello",
               "async" => false,
               "async_processing" => true
             })

    assert payload["async"] == false
  end

  test "an undeclared argument is named in the log rather than vanishing" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Tools.call("retain", %{
          "bank_id" => "bank-a",
          "content" => "hello",
          "totally_made_up" => 1
        })
      end)

    assert log =~ "undeclared arguments"
    assert log =~ "totally_made_up"
  end

  test "a fully declared call logs no warning" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Tools.call("retain", %{"bank_id" => "bank-a", "content" => "hello", "tags" => ["a"]})
      end)

    refute log =~ "undeclared arguments"
  end

  test "retain still honours an explicit async request" do
    assert {:ok, %{op: :retain, payload: payload}} =
             Tools.call("retain", %{
               "bank_id" => "bank-a",
               "content" => "hello",
               "async" => true
             })

    assert payload["async"] == true
  end
end
