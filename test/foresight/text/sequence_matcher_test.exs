defmodule Foresight.Text.SequenceMatcherTest do
  @moduledoc """
  Fidelity tests for the Ratcliff-Obershelp `ratio/2` port.

  Every expected value is the output of Python's
  `difflib.SequenceMatcher(None, a, b).ratio()` — the exact function Hindsight's
  `entity_resolver.py:664` uses for name similarity. If a value here disagrees
  with CPython's difflib, the port is wrong, not the test.
  """
  use ExUnit.Case, async: true

  alias Foresight.Text.SequenceMatcher

  defp r(a, b), do: SequenceMatcher.ratio(a, b)

  describe "ratio/2 matches CPython difflib" do
    test "the load-bearing entity boundary: 'google inc' vs 'google' = 0.75" do
      assert_in_delta r("google inc", "google"), 0.75, 1.0e-9
    end

    test "identical strings = 1.0" do
      assert r("google", "google") == 1.0
      assert r("a", "a") == 1.0
    end

    test "two empty strings = 1.0 (difflib T==0 special case)" do
      assert r("", "") == 1.0
    end

    test "one empty string = 0.0" do
      assert r("abc", "") == 0.0
      assert r("", "abc") == 0.0
    end

    test "interleaved longest-block cases" do
      assert_in_delta r("abcd", "bcde"), 0.75, 1.0e-9
      assert_in_delta r("goggle", "google"), 0.8333333333, 1.0e-9
      assert_in_delta r("kitten", "sitting"), 0.6153846154, 1.0e-9
    end

    test "transposition is not free (unlike Jaro): 'ab' vs 'ba' = 0.5" do
      assert_in_delta r("ab", "ba"), 0.5, 1.0e-9
    end

    test "low-overlap pairs" do
      assert_in_delta r("google", "umbrella"), 0.1428571429, 1.0e-9
      assert_in_delta r("nyc", "new york city"), 0.375, 1.0e-9
    end

    test "substring-extension pairs" do
      assert_in_delta r("new york", "new york city"), 0.7619047619, 1.0e-9
      assert_in_delta r("apple inc", "apple incorporated"), 0.6666666667, 1.0e-9
    end

    test "symmetric within floating tolerance" do
      assert_in_delta r("google inc", "google"), r("google", "google inc"), 1.0e-12
    end
  end
end
