defmodule Foresight.Jobs.WebhookDeliveryWorker do
  @moduledoc false

  use Oban.Worker, queue: :foresight_webhook_delivery, max_attempts: 5

  alias Foresight.AsyncOptions
  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.Schemas.Delivery
  alias Foresight.Schemas.Webhook
  alias Foresight.Tenancy
  alias Foresight.TenantScope

  @impl Oban.Worker
  def perform(%Oban.Job{
        attempt: attempt,
        max_attempts: max_attempts,
        args: %{"context" => context_map, "delivery_id" => delivery_id} = args
      }) do
    ctx = context_from_map(context_map)
    repo = Foresight.Config.get(:engine, :repo, Foresight.Repo)
    http_client = webhook_delivery_config()[:http_client] || Foresight.Webhooks.HttpcClient

    Tenancy.with_tenant_role(
      ctx,
      fn ->
        repo_opts = tenant_repo_opts(ctx)

        with :ok <- TenantScope.validate_context(ctx, Map.get(args, "tenant_scope")),
             %Delivery{} = delivery <- repo.get(Delivery, delivery_id, repo_opts),
             %Webhook{} = webhook <- repo.get(Webhook, delivery.webhook_id, repo_opts),
             {:ok, response} <-
               http_client.post(
                 delivery_url(delivery.url, webhook),
                 delivery_payload(delivery),
                 delivery_options(webhook)
               ),
             true <- response.status in 200..299 do
          update_delivery!(
            repo,
            delivery,
            %{
              status: "delivered",
              attempts: attempt,
              next_retry_at: nil,
              last_error: nil,
              last_response_status: response.status,
              last_response_body: response.body,
              last_attempt_at: now()
            },
            repo_opts
          )

          :ok
        else
          nil ->
            {:discard, Error.new(:not_found, %{message: "delivery not found"})}

          false ->
            update_failure(
              repo,
              repo_opts,
              delivery_id,
              attempt,
              max_attempts,
              "non-success response"
            )

          {:ok, response} ->
            update_failure(
              repo,
              repo_opts,
              delivery_id,
              attempt,
              max_attempts,
              "non-success response: #{response.status}"
            )

          {:error, reason} ->
            update_failure(repo, repo_opts, delivery_id, attempt, max_attempts, inspect(reason))
        end
      end,
      AsyncOptions.restore(args, repo: repo)
    )
  end

  defp update_failure(repo, repo_opts, delivery_id, attempt, max_attempts, error_message) do
    delivery = repo.get!(Delivery, delivery_id, repo_opts)

    status =
      if attempt < max_attempts do
        "pending"
      else
        "failed"
      end

    update_delivery!(
      repo,
      delivery,
      %{
        status: status,
        attempts: attempt,
        last_error: error_message,
        last_attempt_at: now()
      },
      repo_opts
    )

    {:error, Error.new(:unavailable, %{message: error_message})}
  end

  defp update_delivery!(repo, delivery, attrs, repo_opts) do
    delivery
    |> Delivery.changeset(attrs)
    |> repo.update!(repo_opts)
  end

  defp delivery_payload(%Delivery{} = delivery) do
    %{
      "delivery_id" => delivery.id,
      "bank_id" => delivery.bank_id,
      "event_type" => delivery.event_type,
      "payload" => delivery.payload
    }
  end

  # Upper-bound the caller-supplied timeout so a webhook can't pin a slot in the
  # bounded delivery queue for minutes/hours and starve other deliveries.
  @max_timeout_seconds 30

  defp delivery_options(%Webhook{} = webhook) do
    http_config = webhook.http_config || %{}

    timeout_seconds =
      http_config
      |> Map.get("timeout_seconds", 10)
      |> clamp_timeout_seconds()

    [
      timeout_ms: timeout_seconds * 1_000,
      headers: normalize_headers(Map.get(http_config, "headers", %{})),
      sign_secret: webhook.secret
    ]
  end

  defp clamp_timeout_seconds(value) when is_integer(value) and value > 0,
    do: min(value, @max_timeout_seconds)

  defp clamp_timeout_seconds(_value), do: 10

  defp delivery_url(url, %Webhook{} = webhook) do
    http_config = webhook.http_config || %{}
    params = Map.get(http_config, "params", %{})

    uri = URI.parse(url)
    merged_query = URI.decode_query(uri.query || "") |> Map.merge(params)

    %{uri | query: if(map_size(merged_query) == 0, do: nil, else: URI.encode_query(merged_query))}
    |> URI.to_string()
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), to_charlist(to_string(value))}
    end)
  end

  defp normalize_headers(_headers), do: []

  defp webhook_delivery_config do
    Application.get_env(:foresight, :webhook_delivery, [])
  end

  defp tenant_repo_opts(%Context{prefix: prefix}) when is_binary(prefix), do: [prefix: prefix]
  defp tenant_repo_opts(_ctx), do: []

  defp context_from_map(map) do
    %Context{
      tenant_id: map["tenant_id"],
      mode: parse_mode(map["mode"]),
      bank: map["bank"],
      role_name: map["role_name"],
      prefix: map["prefix"],
      embedding_dim: map["embedding_dim"]
    }
  end

  defp parse_mode(nil), do: nil
  defp parse_mode("mode_a"), do: :mode_a
  defp parse_mode("mode_b"), do: :mode_b
  defp parse_mode("mode_c"), do: :mode_c
  defp parse_mode(mode) when is_atom(mode), do: mode
  # Unknown mode string (e.g. a stale atom from an old release) must not raise on
  # every retry and poison the queue; resolve it to nil and let with_tenant_role/3
  # fail closed.
  defp parse_mode(_mode), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
