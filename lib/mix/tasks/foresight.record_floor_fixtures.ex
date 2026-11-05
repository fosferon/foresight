defmodule Mix.Tasks.Foresight.RecordFloorFixtures do
  use Mix.Task

  @shortdoc "Records FLOOR contract fixtures from a live hindsight authority"

  @moduledoc """
  Records the FLOOR fixture set from a live hindsight v0.7.1 authority.

  Environment:

  - `HINDSIGHT_FIXTURE_BASE_URL` — base URL of the live authority, for example `http://127.0.0.1:8888`
  - `HINDSIGHT_FIXTURE_API_KEY` — optional Bearer token
  - `HINDSIGHT_FIXTURE_BANK_ID` — bank to create/use during capture, defaults to `foresight-floor`

  The recorder seeds a bank with a small sync retain before it captures recall/listing fixtures.
  It writes JSON files under `priv/foresight/fixtures/recorded_floor_contract/` and updates `manifest.json`.
  """

  @fixture_root Path.expand("../../../priv/foresight/fixtures/recorded_floor_contract", __DIR__)

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    client = %{
      base_url: required_env!("HINDSIGHT_FIXTURE_BASE_URL") |> String.trim_trailing("/"),
      api_key: System.get_env("HINDSIGHT_FIXTURE_API_KEY"),
      bank_id: System.get_env("HINDSIGHT_FIXTURE_BANK_ID", "foresight-floor")
    }

    File.mkdir_p!(@fixture_root)

    reset_bank!(client)
    seed_bank!(client)
    seed_memories!(client)
    refs = seed_fixture_refs!(client)

    recorded =
      Enum.map(cases(refs), fn %{name: name} = fixture_case ->
        body = request!(client, fixture_case)
        path = Path.join(@fixture_root, name)
        File.write!(path, Jason.encode_to_iodata!(body, pretty: true))
        Mix.shell().info("recorded #{name}")

        %{
          "name" => name,
          "method" => fixture_case.method |> Atom.to_string() |> String.upcase(),
          "path" => fixture_case.path.(client),
          "status" => Map.get(fixture_case, :status, 200),
          "recorded_from_live" => true
        }
      end)
      |> Kernel.++(capture_directive_flow!(client))
      |> Kernel.++(capture_mental_model_flow!(client))
      |> Kernel.++(capture_webhook_flow!(client))
      |> Kernel.++(capture_bank_delete!(client))

    manifest = %{
      "authority" => %{
        "base_url" => client.base_url,
        "version" => "0.7.1",
        "package" => "hindsight-api-slim==0.7.1"
      },
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tier_tags" => ["tier2", "nightly"],
      "fixtures" => recorded
    }

    manifest_path = Path.join(@fixture_root, "manifest.json")
    File.write!(manifest_path, Jason.encode_to_iodata!(manifest, pretty: true))
    Mix.shell().info("updated #{manifest_path}")
  end

  defp reset_bank!(client) do
    _ =
      case request(:delete, client.base_url <> bank_path(client), request_headers(client)) do
        {:ok, {{_http_version, status, _reason_phrase}, _headers, _body}}
        when status in [200, 404] ->
          :ok

        {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} ->
          raise """
          fixture bank reset failed with HTTP #{status}

          #{body}
          """

        {:error, reason} ->
          raise "fixture bank reset failed: #{inspect(reason)}"
      end

    :ok
  end

  defp seed_bank!(client) do
    _ =
      request!(client, %{name: "seed_bank", method: :put, path: &bank_path/1, body: &bank_body/1})

    :ok
  end

  defp seed_fixture_refs!(client) do
    recall =
      request!(client, %{
        name: "seed_recall_refs",
        method: :post,
        path: fn current_client -> "#{bank_path(current_client)}/memories/recall" end,
        body: &recall_body/1
      })

    entities =
      request!(client, %{
        name: "seed_entities_refs",
        method: :get,
        path: fn current_client -> "#{bank_path(current_client)}/entities?limit=5&offset=0" end
      })

    documents =
      request!(client, %{
        name: "seed_documents_refs",
        method: :get,
        path: fn current_client ->
          "#{bank_path(current_client)}/documents?q=doc-7&tags%5B%5D=alpha&tags%5B%5D=beta"
        end
      })

    memory =
      recall
      |> Map.fetch!("results")
      |> List.first()

    entity =
      entities
      |> Map.fetch!("items")
      |> List.first()

    document =
      documents
      |> Map.fetch!("items")
      |> List.first()

    %{
      memory_id: memory["id"],
      chunk_id: memory["chunk_id"],
      entity_id: entity["id"],
      document_id: document["id"]
    }
  end

  defp seed_memories!(client) do
    _ =
      request!(client, %{
        name: "seed_memories",
        method: :post,
        path: fn current_client -> "#{bank_path(current_client)}/memories" end,
        body: fn _ ->
          %{
            "items" => [
              %{
                "content" => "Alice met Bob in Athens. hello from foresight floor seed",
                "context" => "chat",
                "type" => "note",
                "tags" => ["alpha", "beta"],
                "document_id" => "doc-7",
                "metadata" => %{"source" => "fixture-seed"}
              }
            ],
            "async" => false
          }
        end
      })

    :ok
  end

  defp request!(client, fixture_case) do
    path = fixture_case.path.(client)
    url = client.base_url <> path
    headers = request_headers(client)
    expected_status = Map.get(fixture_case, :status, 200)

    response =
      case Map.get(fixture_case, :body) do
        nil ->
          request(fixture_case.method, url, headers)

        body_builder ->
          case body_builder.(client) do
            {:raw, body, content_type} ->
              request(
                fixture_case.method,
                url,
                request_headers(client, content_type),
                body,
                content_type
              )

            body ->
              encoded = body |> Jason.encode_to_iodata!() |> IO.iodata_to_binary()
              request(fixture_case.method, url, headers, encoded)
          end
      end

    case response do
      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}}
      when status == expected_status ->
        Jason.decode!(body)

      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} ->
        raise """
        fixture capture failed for #{fixture_case.name} with HTTP #{status}

        #{body}
        """

      {:error, reason} ->
        raise "fixture capture failed for #{fixture_case.name}: #{inspect(reason)}"
    end
  end

  defp request(method, url, headers) do
    :httpc.request(method, {to_charlist(url), headers}, http_options(), body_format: :binary)
  end

  defp request(method, url, headers, body) do
    :httpc.request(
      method,
      {to_charlist(url), headers, ~c"application/json", body},
      http_options(),
      body_format: :binary
    )
  end

  defp request(method, url, headers, body, content_type) do
    :httpc.request(
      method,
      {to_charlist(url), headers, String.to_charlist(content_type), body},
      http_options(),
      body_format: :binary
    )
  end

  defp http_options do
    [timeout: 30_000, connect_timeout: 30_000]
  end

  defp request_headers(client, content_type \\ "application/json") do
    auth_headers =
      case client.api_key do
        nil -> []
        "" -> []
        api_key -> [{~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}]
      end

    [
      {~c"accept", ~c"application/json"},
      {~c"content-type", String.to_charlist(content_type)}
      | auth_headers
    ]
  end

  defp required_env!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("missing required environment variable #{name}")
      "" -> Mix.raise("missing required environment variable #{name}")
      value -> value
    end
  end

  defp cases(refs) do
    [
      %{name: "health.json", method: :get, path: fn _ -> "/health" end},
      %{name: "version.json", method: :get, path: fn _ -> "/version" end},
      %{name: "bank_put.json", method: :put, path: &bank_path/1, body: &bank_body/1},
      %{name: "banks_list.json", method: :get, path: fn _ -> "/v1/default/banks" end},
      %{
        name: "bank_stats.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/stats" end
      },
      %{
        name: "bank_profile.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/profile" end
      },
      %{
        name: "bank_patch.json",
        method: :patch,
        path: &bank_path/1,
        body: &bank_patch_body/1
      },
      %{
        name: "retain_async.json",
        method: :post,
        path: fn client -> "#{bank_path(client)}/memories" end,
        body: &retain_async_body/1
      },
      %{
        name: "consolidate_trigger.json",
        method: :post,
        path: fn client -> "#{bank_path(client)}/consolidate" end,
        body: fn _ -> %{} end
      },
      %{
        name: "files_retain.json",
        method: :post,
        path: fn client -> "#{bank_path(client)}/files/retain" end,
        body: &files_retain_body/1
      },
      %{
        name: "recall.json",
        method: :post,
        path: fn client -> "#{bank_path(client)}/memories/recall" end,
        body: &recall_body/1
      },
      %{
        name: "reflect.json",
        method: :post,
        path: fn client -> "#{bank_path(client)}/reflect" end,
        body: &reflect_body/1
      },
      %{
        name: "memories_list.json",
        method: :get,
        path: fn client ->
          "#{bank_path(client)}/memories/list?limit=5&offset=2&q=hello&type=note"
        end
      },
      %{
        name: "memory_get.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/memories/#{refs.memory_id}" end
      },
      %{
        name: "memory_history.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/memories/#{refs.memory_id}/history" end
      },
      %{
        name: "entities_list.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/entities?limit=3&offset=1" end
      },
      %{
        name: "entity_graph.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/entities/graph?limit=10&min_count=1" end
      },
      %{
        name: "entity_get.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/entities/#{refs.entity_id}" end
      },
      %{
        name: "entity_regenerate_gone.json",
        method: :post,
        status: 410,
        path: fn client -> "#{bank_path(client)}/entities/#{refs.entity_id}/regenerate" end,
        body: fn _ -> %{} end
      },
      %{
        name: "documents_list.json",
        method: :get,
        path: fn client ->
          "#{bank_path(client)}/documents?q=doc-7&tags%5B%5D=alpha&tags%5B%5D=beta"
        end
      },
      %{
        name: "document_get.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/documents/#{refs.document_id}" end
      },
      %{
        name: "document_chunks.json",
        method: :get,
        path: fn client ->
          "#{bank_path(client)}/documents/#{refs.document_id}/chunks?limit=10&offset=0"
        end
      },
      %{
        name: "document_patch.json",
        method: :patch,
        path: fn client -> "#{bank_path(client)}/documents/#{refs.document_id}" end,
        body: &document_patch_body/1
      },
      %{
        name: "document_reprocess.json",
        method: :post,
        path: fn client -> "#{bank_path(client)}/documents/#{refs.document_id}/reprocess" end,
        body: fn _ -> %{} end
      },
      %{
        name: "memory_graph.json",
        method: :get,
        path: fn client -> "#{bank_path(client)}/graph?limit=10" end
      },
      %{
        name: "chunk_get.json",
        method: :get,
        path: fn client ->
          "/v1/default/chunks/#{refs.chunk_id}?bank_id=#{client.bank_id}"
        end
      },
      %{
        name: "document_delete.json",
        method: :delete,
        path: fn client -> "#{bank_path(client)}/documents/#{refs.document_id}" end
      },
      %{
        name: "clear_observations.json",
        method: :delete,
        path: fn client -> "#{bank_path(client)}/observations" end
      },
      %{
        name: "clear_memory_observations.json",
        method: :delete,
        path: fn client -> "#{bank_path(client)}/memories/#{refs.memory_id}/observations" end
      },
      %{
        name: "clear_memories.json",
        method: :delete,
        path: fn client -> "#{bank_path(client)}/memories" end
      }
    ]
  end

  defp capture_bank_delete!(client) do
    delete_case = %{name: "bank_delete.json", method: :delete, path: &bank_path/1}
    [record_fixture!(client, delete_case, request!(client, delete_case))]
  end

  defp capture_webhook_flow!(client) do
    create_case = %{
      name: "webhook_create.json",
      method: :post,
      status: 201,
      path: fn current_client -> "#{bank_path(current_client)}/webhooks" end,
      body: &webhook_create_body/1
    }

    created = request!(client, create_case)
    webhook_id = Map.fetch!(created, "id")
    webhook_client = Map.put(client, :webhook_id, webhook_id)

    list_case = %{
      name: "webhooks_list.json",
      method: :get,
      path: fn current_client -> "#{bank_path(current_client)}/webhooks" end
    }

    patch_case = %{
      name: "webhook_patch.json",
      method: :patch,
      path: fn current_client -> "#{bank_path(current_client)}/webhooks/#{webhook_id}" end,
      body: &webhook_patch_body/1
    }

    deliveries_case = %{
      name: "webhook_deliveries_list.json",
      method: :get,
      path: fn current_client ->
        "#{bank_path(current_client)}/webhooks/#{webhook_id}/deliveries?limit=10"
      end
    }

    delete_case = %{
      name: "webhook_delete.json",
      method: :delete,
      path: fn current_client -> "#{bank_path(current_client)}/webhooks/#{webhook_id}" end
    }

    _delivery_trigger =
      request!(client, %{
        name: "webhook_delivery_trigger",
        method: :post,
        path: fn current_client -> "#{bank_path(current_client)}/consolidate" end,
        body: fn _ -> %{"tag_scopes" => [%{"tags" => ["alpha"]}]} end
      })

    deliveries =
      wait_for_webhook_deliveries!(webhook_client, deliveries_case, fn response ->
        match?(%{"items" => [_ | _]}, response)
      end)

    [
      record_fixture!(client, create_case, created),
      record_fixture!(client, list_case, request!(client, list_case)),
      record_fixture!(client, patch_case, request!(client, patch_case)),
      record_fixture!(webhook_client, deliveries_case, deliveries),
      record_fixture!(client, delete_case, request!(client, delete_case))
    ]
  end

  defp capture_directive_flow!(client) do
    create_case = %{
      name: "directive_create.json",
      method: :post,
      path: fn current_client -> "#{bank_path(current_client)}/directives" end,
      body: &directive_create_body/1
    }

    created = request!(client, create_case)
    directive_id = Map.fetch!(created, "id")

    list_case = %{
      name: "directives_list.json",
      method: :get,
      path: fn current_client -> "#{bank_path(current_client)}/directives" end
    }

    get_case = %{
      name: "directive_get.json",
      method: :get,
      path: fn current_client -> "#{bank_path(current_client)}/directives/#{directive_id}" end
    }

    patch_case = %{
      name: "directive_patch.json",
      method: :patch,
      path: fn current_client -> "#{bank_path(current_client)}/directives/#{directive_id}" end,
      body: &directive_patch_body/1
    }

    delete_case = %{
      name: "directive_delete.json",
      method: :delete,
      path: fn current_client -> "#{bank_path(current_client)}/directives/#{directive_id}" end
    }

    [
      record_fixture!(client, create_case, created),
      record_fixture!(client, list_case, request!(client, list_case)),
      record_fixture!(client, get_case, request!(client, get_case)),
      record_fixture!(client, patch_case, request!(client, patch_case)),
      record_fixture!(client, delete_case, request!(client, delete_case))
    ]
  end

  defp capture_mental_model_flow!(client) do
    create_case = %{
      name: "mental_model_create.json",
      method: :post,
      path: fn current_client -> "#{bank_path(current_client)}/mental-models" end,
      body: &mental_model_create_body/1
    }

    created = request!(client, create_case)
    mental_model_id = Map.fetch!(created, "mental_model_id")

    list_case = %{
      name: "mental_models_list.json",
      method: :get,
      path: fn current_client -> "#{bank_path(current_client)}/mental-models" end
    }

    get_case = %{
      name: "mental_model_get.json",
      method: :get,
      path: fn current_client ->
        "#{bank_path(current_client)}/mental-models/#{mental_model_id}"
      end
    }

    history_case = %{
      name: "mental_model_history.json",
      method: :get,
      path: fn current_client ->
        "#{bank_path(current_client)}/mental-models/#{mental_model_id}/history"
      end
    }

    refresh_case = %{
      name: "mental_model_refresh.json",
      method: :post,
      path: fn current_client ->
        "#{bank_path(current_client)}/mental-models/#{mental_model_id}/refresh"
      end,
      body: fn _ -> %{} end
    }

    patch_case = %{
      name: "mental_model_patch.json",
      method: :patch,
      path: fn current_client ->
        "#{bank_path(current_client)}/mental-models/#{mental_model_id}"
      end,
      body: &mental_model_patch_body/1
    }

    delete_case = %{
      name: "mental_model_delete.json",
      method: :delete,
      path: fn current_client ->
        "#{bank_path(current_client)}/mental-models/#{mental_model_id}"
      end
    }

    [
      record_fixture!(client, create_case, created),
      record_fixture!(client, list_case, request!(client, list_case)),
      record_fixture!(client, get_case, request!(client, get_case)),
      record_fixture!(client, history_case, request!(client, history_case)),
      record_fixture!(client, refresh_case, request!(client, refresh_case)),
      record_fixture!(client, patch_case, request!(client, patch_case)),
      record_fixture!(client, delete_case, request!(client, delete_case))
    ]
  end

  defp bank_path(client), do: "/v1/default/banks/#{client.bank_id}"

  defp bank_body(_client) do
    %{"name" => "Foresight FLOOR", "mission" => "Record live contract fixtures"}
  end

  defp bank_patch_body(_client) do
    %{"mission" => "patched mission"}
  end

  defp retain_async_body(_client) do
    %{
      "items" => [
        %{
          "content" => "hello from foresight floor async fixture",
          "context" => "chat",
          "type" => "note",
          "tags" => ["alpha", "beta"],
          "document_id" => "doc-8",
          "metadata" => %{"source" => "fixture-async"}
        }
      ],
      "async" => true
    }
  end

  defp files_retain_body(_client) do
    path =
      Path.join(
        System.tmp_dir!(),
        "recorded-floor-files-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "live fixture upload body\n")
    boundary = "----foresight-floor-files-boundary"

    request =
      Jason.encode!(%{
        "files_metadata" => [
          %{
            "document_id" => "doc-live-upload",
            "metadata" => %{"source" => "live-fixture"}
          }
        ]
      })

    body =
      multipart_body(boundary, [
        {:file, "files", path, "fixture.txt", "text/plain"},
        {:field, "request", request}
      ])

    {:raw, body, "multipart/form-data; boundary=#{boundary}"}
  end

  defp recall_body(_client) do
    %{
      "query" => "hello",
      "tags" => ["alpha"],
      "max_tokens" => 4096,
      "trace" => true,
      "include" => %{"chunks" => %{}, "source_facts" => %{}}
    }
  end

  defp reflect_body(_client) do
    %{
      "query" => "hello",
      "include" => %{"facts" => %{}, "tool_calls" => %{}},
      "response_schema" => %{"type" => "object"}
    }
  end

  defp webhook_create_body(_client) do
    %{
      "url" => "http://127.0.0.1:1/foresight-webhook-fixture",
      "secret" => "sk-webhook-fixture-secret",
      "event_types" => ["consolidation.completed"],
      "enabled" => true,
      "http_config" => %{
        "method" => "POST",
        "timeout_seconds" => 3,
        "headers" => %{"x-source" => "foresight-live-fixture"},
        "params" => %{"mode" => "fixture"}
      }
    }
  end

  defp webhook_patch_body(_client) do
    %{
      "enabled" => false,
      "http_config" => %{
        "method" => "GET",
        "timeout_seconds" => 5,
        "headers" => %{},
        "params" => %{"mode" => "fixture-patched"}
      }
    }
  end

  defp directive_create_body(_client) do
    %{
      "name" => "Fixture Directive",
      "content" => "Lead with evidence.",
      "priority" => 3,
      "is_active" => true,
      "tags" => ["alpha"]
    }
  end

  defp directive_patch_body(_client) do
    %{
      "content" => "Lead with concrete evidence.",
      "tags" => ["alpha", "beta"]
    }
  end

  defp document_patch_body(_client) do
    %{
      "tags" => ["alpha", "beta", "live-recorded"]
    }
  end

  defp mental_model_create_body(_client) do
    %{
      "id" => "fixture-mental-model",
      "name" => "Fixture Mental Model",
      "source_query" => "What do we know about the seeded hello memory?",
      "tags" => ["alpha"]
    }
  end

  defp mental_model_patch_body(_client) do
    %{
      "name" => "Fixture Mental Model Updated",
      "source_query" => "What do we know about the seeded alpha memory?",
      "tags" => ["alpha", "beta"],
      "max_tokens" => 1024,
      "trigger" => %{"refresh_after_consolidation" => true}
    }
  end

  defp record_fixture!(client, fixture_case, body) do
    path = Path.join(@fixture_root, fixture_case.name)
    File.write!(path, Jason.encode_to_iodata!(body, pretty: true))
    Mix.shell().info("recorded #{fixture_case.name}")

    %{
      "name" => fixture_case.name,
      "method" => fixture_case.method |> Atom.to_string() |> String.upcase(),
      "path" => fixture_case.path.(client),
      "status" => Map.get(fixture_case, :status, 200),
      "recorded_from_live" => true
    }
  end

  defp wait_for_webhook_deliveries!(client, fixture_case, ready?) do
    1..20
    |> Enum.reduce_while(nil, fn _attempt, _acc ->
      response = request!(client, fixture_case)

      if ready?.(response) do
        {:halt, response}
      else
        Process.sleep(250)
        {:cont, nil}
      end
    end)
    |> case do
      nil -> Mix.raise("webhook deliveries did not appear during fixture capture")
      response -> response
    end
  end

  defp multipart_body(boundary, parts) do
    parts
    |> Enum.map_join(&multipart_part(boundary, &1))
    |> Kernel.<>("--#{boundary}--\r\n")
  end

  defp multipart_part(boundary, {:field, name, value}) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"\r\n",
      "\r\n",
      value,
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp multipart_part(boundary, {:file, name, path, filename, content_type}) do
    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n",
      "content-type: #{content_type}\r\n",
      "\r\n",
      File.read!(path),
      "\r\n"
    ]
    |> IO.iodata_to_binary()
  end
end
