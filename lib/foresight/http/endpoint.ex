defmodule Foresight.HTTP.Endpoint do
  @moduledoc false

  def child_spec(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    router_options =
      opts
      |> Keyword.get(:router_options, [])
      |> Keyword.put(:config, Keyword.fetch!(opts, :config))

    bandit_options = [
      plug: {Foresight.HTTP.Router, router_options},
      ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
      port: Keyword.get(opts, :port, 4001),
      startup_log: false
    ]

    %{
      id: {:http_endpoint, name},
      start: {Bandit, :start_link, [bandit_options]}
    }
  end
end
