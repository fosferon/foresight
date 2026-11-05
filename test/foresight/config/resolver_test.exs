defmodule Foresight.Config.ResolverTest do
  use ExUnit.Case, async: true

  alias Foresight.Config.Fields
  alias Foresight.Config.Resolver
  alias Foresight.Context

  test "normalizes python and env-style update keys and rejects static fields" do
    assert {:ok,
            %{
              "embed_model" => "custom/model",
              "embedding_dim" => 384,
              "recall_max_tokens" => 1024,
              "recall_rerank_window" => 80,
              "reflect_mission" => "mission"
            }} =
             Fields.normalize_updates(%{
               "HINDSIGHT_API_RECALL_MAX_TOKENS" => 1024,
               "HINDSIGHT_API_RECALL_RERANK_WINDOW" => 80,
               :reflect_mission => "mission",
               "embed_model" => "custom/model",
               "embedding_dim" => 384
             })

    assert {:error, ["background"]} =
             Fields.normalize_updates(%{"background" => "not configurable"})
  end

  test "resolves global tenant bank hierarchy and bank tombstones fall back" do
    ctx = %Context{tenant_id: "tenant-a", mode: :mode_a, bank: "fosferon"}

    runtime_config = %{
      bank_config: %{
        global: %{
          "reflect_mission" => "global mission",
          "recall_max_tokens" => 2048
        },
        tenants: %{
          "tenant-a" => %{
            "reflect_mission" => "tenant mission",
            "recall_max_tokens" => 1536
          }
        }
      }
    }

    resolved =
      Resolver.resolve(
        ctx,
        %{"reflect_mission" => nil, "recall_max_tokens" => 1024},
        runtime_config
      )

    assert resolved.config["reflect_mission"] == "tenant mission"
    assert resolved.config["recall_max_tokens"] == 1024
    assert resolved.overrides == %{"recall_max_tokens" => 1024}
  end

  test "apply_updates removes nil tombstones from stored bank overrides" do
    assert Resolver.apply_updates(
             %{"reflect_mission" => "bank mission", "recall_max_tokens" => 2048},
             %{"reflect_mission" => nil, "recall_max_tokens" => 1024}
           ) == %{"recall_max_tokens" => 1024}
  end
end
