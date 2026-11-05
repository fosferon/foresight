defmodule Foresight.Reflect.LoopOptions do
  @moduledoc """
  Guards the options reflect hands to `LlmCore.Agent.Loop`.

  Reflect accumulates grounding (cited ids, tool calls, token usage) in the calling
  process's dictionary while the loop runs its iteration pipeline synchronously in
  that same process. An asynchronous pipeline would run the stages elsewhere and
  silently lose every grounding write, so that configuration is refused up front.
  """

  @doc "Attach caller-supplied pipeline options to the loop options, refusing async ones."
  @spec with_pipeline_opts(keyword(), keyword() | nil) :: keyword()
  def with_pipeline_opts(loop_opts, nil), do: loop_opts

  def with_pipeline_opts(loop_opts, pipeline_opts) when is_list(pipeline_opts) do
    :ok = assert_sync!(pipeline_opts)
    Keyword.put(loop_opts, :pipeline_opts, pipeline_opts)
  end

  @doc "Raise unless the pipeline runs synchronously (the default)."
  @spec assert_sync!(keyword()) :: :ok
  def assert_sync!(pipeline_opts) when is_list(pipeline_opts) do
    if Keyword.get(pipeline_opts, :sync, true) == false do
      raise ArgumentError,
            "reflect's agentic loop must run its pipeline synchronously (sync: true): " <>
              "grounding is accumulated in the calling process and an async pipeline would lose it"
    end

    :ok
  end
end
