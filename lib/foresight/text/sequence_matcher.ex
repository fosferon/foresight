defmodule Foresight.Text.SequenceMatcher do
  @moduledoc """
  Faithful port of Python `difflib.SequenceMatcher(None, a, b).ratio()` — the
  Ratcliff-Obershelp similarity Hindsight uses for entity name matching
  (`engine/entity_resolver.py:664`).

  `ratio/2` returns `2.0 * M / T` where `M` is the total number of matched
  characters across the recursively-discovered longest matching blocks and
  `T = length(a) + length(b)`. Empty-vs-empty returns `1.0` (difflib's `T == 0`
  special case).

  ## Fidelity scope

  CPython's `SequenceMatcher` has two knobs this port deliberately omits, both
  provably inert for the entity-name domain it serves:

    * **`isjunk`** — Hindsight always passes `None`, so no element is junk. With
      no junk, the DP below already yields maximal contiguous runs, and difflib's
      junk-extension loops never fire. Omitting them is exact, not approximate.
    * **autojunk** — difflib treats an element as junk when the second sequence
      has more than 200 items and the element occupies >1% of them. Entity names
      are far shorter than 200 characters, so autojunk never triggers. This port
      does not implement it; feeding it a >200-char `b` with a hot character would
      diverge from difflib, which is out of scope by construction.

  Operates on Unicode code points (`String.to_charlist/1`), matching Python's
  per-character iteration over `str`. Pure and side-effect-free.
  """

  @doc """
  Ratcliff-Obershelp similarity ratio in `[0.0, 1.0]`, byte-faithful to
  `difflib.SequenceMatcher(None, a, b).ratio()` within the fidelity scope above.
  """
  @spec ratio(String.t(), String.t()) :: float()
  def ratio(a, b) when is_binary(a) and is_binary(b) do
    a_cl = String.to_charlist(a)
    b_cl = String.to_charlist(b)
    total = length(a_cl) + length(b_cl)

    if total == 0 do
      1.0
    else
      matches = total_matches(a_cl, b_cl)
      2.0 * matches / total
    end
  end

  defp total_matches(a_cl, b_cl) do
    a = List.to_tuple(a_cl)
    b2j = build_b2j(b_cl)
    sum_blocks([{0, length(a_cl), 0, length(b_cl)}], a, b2j, 0)
  end

  # char => ascending list of its indices in b (difflib's b2j, no junk removal)
  defp build_b2j(b_cl) do
    b_cl
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {ch, idx}, acc ->
      Map.update(acc, ch, [idx], &[idx | &1])
    end)
    |> Map.new(fn {ch, idxs} -> {ch, Enum.reverse(idxs)} end)
  end

  # Explicit-stack port of difflib.get_matching_blocks: find the longest match in
  # the window, then recurse on the sub-windows left and right of it, summing the
  # matched sizes.
  defp sum_blocks([], _a, _b2j, acc), do: acc

  defp sum_blocks([{alo, ahi, blo, bhi} | rest], a, b2j, acc) do
    {i, j, k} = find_longest_match(a, b2j, alo, ahi, blo, bhi)

    if k > 0 do
      sum_blocks([{alo, i, blo, j}, {i + k, ahi, j + k, bhi} | rest], a, b2j, acc + k)
    else
      sum_blocks(rest, a, b2j, acc)
    end
  end

  # difflib.find_longest_match without the junk branches (see @moduledoc). Returns
  # {besti, bestj, bestsize}: leftmost-in-a, then leftmost-in-b, longest run.
  defp find_longest_match(_a, _b2j, alo, ahi, blo, blo_hi) when ahi <= alo or blo_hi <= blo,
    do: {alo, blo, 0}

  defp find_longest_match(a, b2j, alo, ahi, blo, bhi) do
    {best, _j2len} =
      Enum.reduce(alo..(ahi - 1)//1, {{alo, blo, 0}, %{}}, fn i, {best, j2len} ->
        js = Map.get(b2j, elem(a, i), [])
        extend_row(js, i, blo, bhi, j2len, best)
      end)

    best
  end

  # One row of the DP: for each b-index j where b[j] == a[i], the length of the
  # match ending at (i, j) is j2len[j-1] + 1. Returns {best, new_j2len} to match
  # find_longest_match's accumulator order.
  defp extend_row(js, i, blo, bhi, j2len, best) do
    Enum.reduce_while(js, {best, %{}}, fn j, {best, new_j2len} ->
      cond do
        j < blo ->
          {:cont, {best, new_j2len}}

        j >= bhi ->
          {:halt, {best, new_j2len}}

        true ->
          k = Map.get(j2len, j - 1, 0) + 1
          new_j2len = Map.put(new_j2len, j, k)
          best = if k > elem(best, 2), do: {i - k + 1, j - k + 1, k}, else: best
          {:cont, {best, new_j2len}}
      end
    end)
  end
end
