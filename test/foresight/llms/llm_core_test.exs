defmodule Foresight.LLMs.LlmCoreTest do
  use ExUnit.Case, async: false

  alias LlmCore.LLM.Error, as: LlmError

  setup do
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :engine, %{
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      llm: Foresight.LLMs.LlmCore,
      provider: Foresight.TestSupport.FakeLlmCoreProvider,
      provider_opts: []
    })

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    :ok
  end

  test "complete_structured dispatches through llm_core provider and returns a struct" do
    prompt =
      Foresight.Prompts.Reflect.V1.build(
        "alpha",
        %{"budget" => "mid"},
        %{
          "bank_id" => "fosferon",
          "name" => "Fosferon",
          "mission" => "Remember",
          "disposition" => %{"skepticism" => 3}
        },
        [%{"content" => "alpha memory"}],
        %{"count" => 1, "freshness" => "up_to_date", "is_stale" => false, "observations" => []}
      )

    assert {:ok,
            %Foresight.Prompts.ReflectResponse{
              text: text,
              directive_compliance: %{"status" => status, "notes" => notes}
            }} =
             Foresight.LLMs.LlmCore.complete_structured(
               prompt,
               [],
               Foresight.Prompts.ReflectResponse,
               []
             )

    assert text =~ "structured:"
    assert text =~ "Query: alpha"
    assert status =~ "structured:"
    assert notes =~ "structured:"
  end

  test "complete_json_schema dispatches through llm_core provider and returns a map" do
    schema = %{
      "type" => "object",
      "required" => ["summary", "grounded"],
      "properties" => %{
        "summary" => %{"type" => "string"},
        "grounded" => %{"type" => "boolean"}
      }
    }

    assert {:ok, %{"summary" => summary, "grounded" => true}} =
             Foresight.LLMs.LlmCore.complete_json_schema(
               %{query: "alpha"},
               Foresight.Prompts.Reflect.Structured.V1.messages("alpha", "answer", schema),
               schema,
               []
             )

    assert summary =~ "structured:"
  end

  test "complete_json_schema records the call in an open usage ledger" do
    schema = %{
      "type" => "object",
      "required" => ["summary"],
      "properties" => %{"summary" => %{"type" => "string"}}
    }

    Foresight.Usage.start()

    assert {:ok, _} =
             Foresight.LLMs.LlmCore.complete_json_schema(
               %{query: "alpha"},
               Foresight.Prompts.Reflect.Structured.V1.messages("alpha", "answer", schema),
               schema,
               usage_role: :extract
             )

    assert [entry] = Foresight.Usage.drain()

    assert %{
             "kind" => "llm",
             "role" => "extract",
             "provider" => "fake",
             "model" => "fake",
             "input_tokens" => 7,
             "output_tokens" => 3,
             "total_tokens" => 10,
             "request_id" => "fake-req-1",
             "status" => "ok"
           } = entry
  end

  test "complete_json_schema records nothing when no ledger is open" do
    schema = %{"type" => "object", "properties" => %{"summary" => %{"type" => "string"}}}

    assert {:ok, _} =
             Foresight.LLMs.LlmCore.complete_json_schema(%{query: "alpha"}, [], schema, [])

    assert Foresight.Usage.drain() == []
  end

  test "complete_structured returns a typed provider error when the provider seam crashes" do
    original_engine = Application.get_env(:foresight, :engine)

    Application.put_env(:foresight, :engine, %{
      storage: Foresight.Storage.Ecto,
      repo: Foresight.Repo,
      embedder: Foresight.Embedders.Noop,
      llm: Foresight.LLMs.LlmCore,
      provider: Foresight.TestSupport.RaisingLlmCoreProvider,
      provider_opts: []
    })

    on_exit(fn ->
      if original_engine do
        Application.put_env(:foresight, :engine, original_engine)
      else
        Application.delete_env(:foresight, :engine)
      end
    end)

    prompt = "Summarize the current Foresight cutover posture."

    assert {:error, %LlmError{type: :provider_error, provider: provider, message: message}} =
             Foresight.LLMs.LlmCore.complete_structured(
               prompt,
               [],
               Foresight.Prompts.ReflectResponse,
               []
             )

    assert provider == Foresight.TestSupport.RaisingLlmCoreProvider
    assert message =~ "no function clause matching in Access.get/3"
  end

  test "local OpenAI-compatible providers clamp prompt budget below the unknown appliance window" do
    original_appliance_max_context = Application.get_env(:llm_core, :appliance_max_context)
    original_appliance_max_tokens = Application.get_env(:llm_core, :appliance_max_tokens)

    on_exit(fn ->
      if is_nil(original_appliance_max_context) do
        Application.delete_env(:llm_core, :appliance_max_context)
      else
        Application.put_env(:llm_core, :appliance_max_context, original_appliance_max_context)
      end

      if is_nil(original_appliance_max_tokens) do
        Application.delete_env(:llm_core, :appliance_max_tokens)
      else
        Application.put_env(:llm_core, :appliance_max_tokens, original_appliance_max_tokens)
      end
    end)

    Application.delete_env(:llm_core, :appliance_max_context)
    Application.delete_env(:llm_core, :appliance_max_tokens)

    assert Foresight.LLMs.LlmCore.max_context_tokens(
             provider: "openai",
             provider_opts: [base_url: "http://127.0.0.1:1234/v1", api_key: "lm-studio"]
           ) == 4_096

    assert Foresight.LLMs.LlmCore.prompt_budget_tokens(
             provider: "openai",
             provider_opts: [base_url: "http://127.0.0.1:1234/v1", api_key: "lm-studio"]
           ) == 3_072

    Application.put_env(:llm_core, :appliance_max_context, 4_096)
    Application.put_env(:llm_core, :appliance_max_tokens, 512)

    assert Foresight.LLMs.LlmCore.max_context_tokens(
             provider: "openai",
             provider_opts: [base_url: "http://127.0.0.1:1234/v1", api_key: "lm-studio"]
           ) == 4_096

    assert Foresight.LLMs.LlmCore.prompt_budget_tokens(
             provider: "openai",
             provider_opts: [base_url: "http://127.0.0.1:1234/v1", api_key: "lm-studio"]
           ) == 3_584
  end
end
