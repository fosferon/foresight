defmodule Foresight.Reflect.ExpandTest do
  use ExUnit.Case, async: true

  alias Foresight.Reflect.Expand

  test "depth defaults to chunk and only accepts document otherwise" do
    assert Expand.depth("document") == "document"
    assert Expand.depth("chunk") == "chunk"
    assert Expand.depth(nil) == "chunk"
    assert Expand.depth("everything") == "chunk"
  end

  test "cited_ids lists expanded units and their neighbours once" do
    expanded = [
      %{"id" => "a", "chunk" => %{"before" => [%{"id" => "x"}], "after" => [%{"id" => "b"}]}},
      %{"id" => "b", "chunk" => %{"before" => [%{"id" => "a"}], "after" => []}},
      %{"id" => "c"}
    ]

    assert Expand.cited_ids(expanded) == ["a", "x", "b", "c"]
  end

  test "ids are de-duplicated, filtered to well-formed ids and capped" do
    good = for _ <- 1..30, do: Ecto.UUID.generate()
    [first | _] = good

    assert Expand.normalize_ids([first, first, "not-an-id", nil] ++ good) ==
             Enum.take(good, Expand.max_ids())

    assert Expand.normalize_ids(nil) == []
    assert Expand.normalize_ids("single") == []
  end
end
