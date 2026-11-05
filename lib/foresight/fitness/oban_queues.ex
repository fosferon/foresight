defmodule Foresight.Fitness.ObanQueues do
  @moduledoc """
  Fitness check: every `Oban.Worker`'s declared queue must exist in the resolved
  Oban configuration.

  A worker whose queue is not declared enqueues "successfully" and then never runs —
  the job sits `available` forever while status endpoints report `pending`. This
  check fails closed on that class of silent job loss.
  """

  @jobs_dir Path.expand("../jobs", __DIR__)
  @queue_pattern ~r/use\s+Oban\.Worker\s*,\s*queue:\s*:([a-z0-9_]+)/

  @type violation :: %{worker_file: String.t(), queue: atom(), reason: String.t()}

  @spec violations() :: [violation()]
  @spec violations(keyword()) :: [violation()]
  def violations(config_overrides \\ [oban: [enabled: true]]) do
    configured = MapSet.new(configured_queues(config_overrides))

    declared_queues()
    |> Enum.reject(fn {_file, queue} -> MapSet.member?(configured, queue) end)
    |> Enum.map(fn {file, queue} ->
      %{
        worker_file: file,
        queue: queue,
        reason: "Oban.Worker queue #{inspect(queue)} is not declared in resolved config"
      }
    end)
  end

  @spec declared_queues() :: [{String.t(), atom()}]
  def declared_queues do
    @jobs_dir
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case Regex.run(@queue_pattern, File.read!(file)) do
        [_, queue] -> [{Path.basename(file), String.to_atom(queue)}]
        _ -> []
      end
    end)
  end

  @spec configured_queues(keyword()) :: [atom()]
  def configured_queues(config_overrides) do
    config_overrides
    |> Foresight.Config.resolve()
    |> get_in([:oban, :queues])
    |> normalize_queues()
    |> Enum.map(fn {queue, _concurrency} -> queue end)
  end

  defp normalize_queues(queues) when is_map(queues), do: Map.to_list(queues)
  defp normalize_queues(queues) when is_list(queues), do: queues
  defp normalize_queues(_), do: []
end
