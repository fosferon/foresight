defmodule Foresight.Storage.KeywordTermsTest do
  @moduledoc """
  Guards the keyword-fidelity fix: keyword_terms/1 must NOT strip
  meaningful words with a custom stopword list — stopword removal is delegated
  entirely to Postgres's `english` text-search config (via to_tsquery). Faithful
  to Hindsight's tokenize_query.
  """
  use ExUnit.Case, async: true

  alias Foresight.Storage.Ecto, as: StorageEcto

  test "keeps meaningful words the old custom stopword list wrongly stripped" do
    terms = StorageEcto.keyword_terms("the real reason it was not simply working")

    for word <- ~w(real reason was not simply working) do
      assert word in terms,
             "expected #{inspect(word)} to survive tokenization, got #{inspect(terms)}"
    end
  end

  test "no minimum-length filter (short tokens survive; Postgres handles stopwords)" do
    assert "ml" in StorageEcto.keyword_terms("ml ops pipeline")
  end

  test "lowercases, strips punctuation, splits on non-word runs, dedups" do
    assert StorageEcto.keyword_terms("Google's Q3-2024 revenue, revenue!") ==
             ["google", "s", "q3", "2024", "revenue"]
  end

  test "empty / punctuation-only query yields no terms" do
    assert StorageEcto.keyword_terms("   ") == []
    assert StorageEcto.keyword_terms("!?.,") == []
  end

  describe "keyword_tsquery/1 (F3)" do
    test "OR-joins raw tokens with NO :* prefix (faithful to Hindsight's tsvector path)" do
      q = StorageEcto.keyword_tsquery("running quickly")
      assert q == "running | quickly"
      refute String.contains?(q, ":*")
    end
  end
end
