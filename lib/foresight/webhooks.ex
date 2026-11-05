defmodule Foresight.Webhooks do
  @moduledoc false

  import Ecto.Query

  alias Foresight.AsyncOptions
  alias Foresight.Context
  alias Foresight.Error
  alias Foresight.Jobs.WebhookDeliveryWorker
  alias Foresight.Schemas.Delivery
  alias Foresight.Schemas.Webhook
  alias Foresight.Tenancy
  alias Foresight.TenantScope

  @spec enqueue_event(Context.t(), String.t(), map(), keyword()) :: :ok | {:error, Error.t()}
  def enqueue_event(%Context{} = ctx, event_type, payload, opts) when is_binary(event_type) do
    repo = Keyword.fetch!(opts, :repo)

    oban_name =
      Keyword.get(opts, :oban_name, Application.get_env(:foresight, :oban_name, Foresight.Oban))

    repo_opts = Keyword.fetch!(opts, :repo_opts)

    with {:ok, tenant_scope} <-
           TenantScope.authorized_snapshot(ctx, Keyword.get(opts, :tenant_scope)),
         {:ok, jobs} <-
           create_deliveries(
             repo,
             repo_opts,
             ctx,
             tenant_scope,
             event_type,
             payload,
             opts
           ),
         :ok <-
           enqueue_delivery_jobs(
             repo,
             oban_name,
             ctx,
             repo_opts,
             jobs,
             opts
           ) do
      :ok
    end
  end

  defp create_deliveries(repo, repo_opts, ctx, tenant_scope, event_type, payload, opts) do
    Tenancy.with_tenant_role(
      ctx,
      fn ->
        webhooks =
          repo.all(
            from(webhook in Webhook,
              where:
                webhook.bank_id == ^ctx.bank and webhook.enabled == true and
                  ^event_type in webhook.event_types
            ),
            repo_opts
          )

        context_map = context_to_map(ctx)

        repo.transaction(
          fn ->
            Enum.map(webhooks, fn webhook ->
              delivery =
                %Delivery{}
                |> Delivery.changeset(%{
                  bank_id: ctx.bank,
                  webhook_id: webhook.id,
                  event_type: event_type,
                  url: webhook.url,
                  payload: payload,
                  status: "pending",
                  attempts: 0
                })
                |> repo.insert!(repo_opts)

              %{
                delivery_id: delivery.id,
                context: context_map,
                tenant_scope: tenant_scope
              }
            end)
          end,
          repo_opts
        )
      end,
      [repo: repo] ++ Keyword.take(opts, [:rls_enabled])
    )
    |> case do
      {:ok, jobs} -> {:ok, jobs}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:unavailable, %{message: inspect(reason)})}
    end
  end

  defp enqueue_delivery_jobs(repo, oban_name, ctx, repo_opts, jobs, opts) do
    jobs
    |> Enum.reduce([], fn job_args, errors ->
      job =
        %{
          "context" => job_args.context,
          "tenant_scope" => job_args.tenant_scope,
          "delivery_id" => job_args.delivery_id
        }
        |> AsyncOptions.put_job_options(opts)
        |> WebhookDeliveryWorker.new()

      case Oban.insert(oban_name, job) do
        {:ok, _inserted_job} ->
          errors

        {:error, reason} ->
          mark_enqueue_failure(repo, ctx, repo_opts, job_args.delivery_id, reason, opts)
          [inspect(reason) | errors]
      end
    end)
    |> case do
      [] ->
        :ok

      reasons ->
        {:error,
         Error.new(:unavailable, %{
           message: "failed to enqueue webhook delivery",
           reason: Enum.reverse(reasons) |> Enum.join("; ")
         })}
    end
  end

  defp mark_enqueue_failure(repo, ctx, repo_opts, delivery_id, reason, opts) do
    Tenancy.with_tenant_role(
      ctx,
      fn ->
        delivery = repo.get!(Delivery, delivery_id, repo_opts)

        delivery
        |> Delivery.changeset(%{
          status: "failed",
          last_error: "failed to enqueue webhook delivery: #{inspect(reason)}"
        })
        |> repo.update!(repo_opts)
      end,
      [repo: repo] ++ Keyword.take(opts, [:rls_enabled])
    )
  end

  defp context_to_map(%Context{} = ctx) do
    %{
      "tenant_id" => ctx.tenant_id,
      "mode" => ctx.mode && Atom.to_string(ctx.mode),
      "bank" => ctx.bank,
      "role_name" => ctx.role_name,
      "prefix" => ctx.prefix,
      "embedding_dim" => ctx.embedding_dim
    }
  end
end
