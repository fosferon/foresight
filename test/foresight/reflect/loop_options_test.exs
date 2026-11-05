defmodule Foresight.Reflect.LoopOptionsTest do
  use ExUnit.Case, async: true

  alias Foresight.Reflect.LoopOptions

  test "no pipeline options leaves the loop options untouched" do
    assert LoopOptions.with_pipeline_opts([max_iterations: 3], nil) == [max_iterations: 3]
  end

  test "synchronous pipeline options are attached" do
    assert LoopOptions.with_pipeline_opts([], sync: true) == [pipeline_opts: [sync: true]]
  end

  test "an async pipeline is refused because grounding would be lost" do
    assert_raise ArgumentError, ~r/synchronously/, fn ->
      LoopOptions.with_pipeline_opts([], sync: false)
    end
  end
end
