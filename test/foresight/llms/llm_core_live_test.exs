defmodule Foresight.LLMs.LlmCoreLiveTest do
  use ExUnit.Case, async: false

  @moduletag :ml
  @tag timeout: 300_000

  setup do
    if not lmstudio_available?() do
      {:ok, skip: "LMStudio is not available on http://127.0.0.1:1234/v1"}
    else
      original_engine = Application.get_env(:foresight, :engine)

      Application.put_env(:foresight, :engine,
        storage: Foresight.Storage.Ecto,
        repo: Foresight.Repo,
        embedder: Foresight.Embedders.Noop,
        llm: Foresight.LLMs.LlmCore,
        provider: "openai",
        provider_opts: [
          base_url: "http://127.0.0.1:1234/v1",
          api_key: "lm-studio",
          model: lmstudio_model!(),
          timeout: 180_000
        ]
      )

      on_exit(fn ->
        if original_engine do
          Application.put_env(:foresight, :engine, original_engine)
        else
          Application.delete_env(:foresight, :engine)
        end
      end)

      :ok
    end
  end

  test "complete_json_schema returns structured output through the OpenAI-compatible LMStudio path" do
    schema = %{
      "title" => "foresight_live_smoke",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["summary", "grounded"],
      "properties" => %{
        "summary" => %{"type" => "string"},
        "grounded" => %{"type" => "boolean"}
      }
    }

    messages = [
      %{
        role: :system,
        content: "Return concise grounded JSON matching the schema."
      },
      %{
        role: :user,
        content:
          "Summarize this fact in one sentence: Foresight is an Elixir memory library with retrieval and reflection."
      }
    ]

    assert {:ok, %{"summary" => summary, "grounded" => grounded}} =
             Foresight.LLMs.LlmCore.complete_json_schema(
               %{query: "foresight-live-smoke"},
               messages,
               schema,
               []
             )

    assert is_binary(summary)
    assert String.trim(summary) != ""
    assert grounded in [true, false]
    assert String.downcase(summary) =~ "foresight"
  end

  defp lmstudio_available? do
    case Req.get("http://127.0.0.1:1234/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> true
      _other -> false
    end
  end

  defp lmstudio_model! do
    case Req.get("http://127.0.0.1:1234/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: status, body: %{"data" => [%{"id" => model} | _]}}}
      when status in 200..299 and is_binary(model) and model != "" ->
        model

      other ->
        raise "Unable to discover an LMStudio model: #{inspect(other)}"
    end
  end
end
