defmodule Foresight.TestSupport.MCPClient.StreamableHTTPClientSupervisor do
  @moduledoc false

  use Supervisor

  alias Hermes.Client.Base

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {transport_layer, transport_opts} = Keyword.fetch!(opts, :transport)

    transport_name = Keyword.fetch!(opts, :transport_name)
    client_name = Keyword.fetch!(opts, :client_name)

    client_opts = [
      transport: [layer: Hermes.Transport.StreamableHTTP, name: transport_name],
      client_info: Keyword.fetch!(opts, :client_info),
      capabilities: Keyword.fetch!(opts, :capabilities),
      protocol_version: Keyword.fetch!(opts, :protocol_version),
      name: client_name
    ]

    children = [
      {Base, client_opts},
      {transport_layer, transport_opts ++ [name: transport_name, client: client_name]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
