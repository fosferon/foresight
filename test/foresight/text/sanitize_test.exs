defmodule Foresight.Text.SanitizeTest do
  use ExUnit.Case, async: true

  alias Foresight.Text.Sanitize

  test "strips control characters but keeps tab, newline and carriage return" do
    assert Sanitize.llm_output("a\x00b\x01c\x7Fd\te\nf\rg") == "abcd\te\nf\rg"
  end

  test "drops bytes that are not valid UTF-8" do
    assert Sanitize.llm_output("ok" <> <<0xFF, 0xFE>> <> "fine") == "okfine"
  end

  test "passes nil, empty and clean text through" do
    assert Sanitize.llm_output(nil) == nil
    assert Sanitize.llm_output("") == ""
    assert Sanitize.llm_output("Alice — café ✓") == "Alice — café ✓"
  end
end
