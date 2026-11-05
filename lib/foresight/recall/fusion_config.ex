defmodule Foresight.Recall.FusionConfig do
  @moduledoc """
  Resolves the option list handed to `Foresight.Recall.RRF.fuse/2`.

  Calibrated fusion is driven by the global `:recall_fusion` app
  config, and those parameters can also be learned PER BANK, so this resolves two
  layers: the global config, then a bank's `config_overrides["recall_fusion"]` on top.

  Bank overrides arrive from JSONB, so mode and normalization come back as strings and are
  coerced to atoms against a closed allowlist — an unrecognised value is ignored rather
  than crashing recall or silently selecting a different fusion mode.

  A bank with no override must resolve to exactly what the global layer alone produces;
  learned weights are opt-in per bank and absent means unchanged.
  """

  # These MUST match Foresight.Recall.RRF.finalize/3's clauses and stat/2's atoms exactly.
  # An allowlist that admits a mode RRF has no clause for turns a bank config into a
  # FunctionClauseError inside recall, which is worse than rejecting it here.
  # Note per-arm :weights are consulted ONLY by :normalized and :hybrid — under :rrf the
  # fuser ranks on reciprocal rank alone and ignores weights entirely.
  @fusion_modes %{
    "rrf" => :rrf,
    "normalized" => :normalized,
    "hybrid" => :hybrid
  }

  @normalizations %{
    "min_max" => :min_max,
    "zscore" => :zscore
  }

  # Measured, not chosen by taste. 134 queries carrying at least one non-zero
  # graded-relevance label, every mode scored on the SAME queries with uniform weights so
  # the comparison isolates the mode, paired per query, 2000-sample bootstrap:
  #
  #   mode                   nDCG@10   MRR      vs :rrf   95% CI             W/L/T
  #   :rrf (was the default) 0.7670    0.7760   —         —                  —
  #   :normalized/min_max    0.8273    0.8508   +0.0603   [0.0322, 0.0906]   50/18/66
  #   :normalized/zscore     0.8679    0.9027   +0.1009   [0.0597, 0.1476]   51/20/63
  #   :hybrid/zscore         0.8661    0.9002   +0.0991   [0.0581, 0.1459]   51/20/63
  #
  # Both intervals exclude 0. :rrf discards the arm scores and merges on rank position
  # alone, so a 0.95 match and a 0.31 match are indistinguishable once they are 1st and
  # 2nd; normalizing the native scores keeps that gap. zscore beats min_max because a
  # single outlier compresses a min_max range while a standard-deviation scale does not.
  #
  # MRR 0.7760 -> 0.9027 is the part that matters downstream: reflect consumes the top of
  # this list, so this is "the right memory is at rank 1" far more often.
  @defaults [
    fusion: :normalized,
    normalization: :zscore,
    weights: %{},
    convergence_bonus: 0.1,
    hybrid_alpha: 1.0
  ]

  @doc """
  Resolve fusion opts from the global layer with an optional per-bank layer on top.

  `global` is the `:recall_fusion` app config (keyword list or map). `bank` is a bank's
  `config_overrides["recall_fusion"]` map, or nil.
  """
  @spec resolve(term(), term()) :: keyword()
  def resolve(global, bank \\ nil) do
    [
      fusion: pick(global, bank, :mode, &coerce_mode/1, @defaults[:fusion]),
      normalization:
        pick(global, bank, :normalization, &coerce_normalization/1, @defaults[:normalization]),
      weights: pick(global, bank, :weights, &coerce_weights/1, @defaults[:weights]),
      convergence_bonus:
        pick(global, bank, :convergence_bonus, &coerce_number/1, @defaults[:convergence_bonus]),
      hybrid_alpha: pick(global, bank, :hybrid_alpha, &coerce_number/1, @defaults[:hybrid_alpha])
    ]
  end

  @doc "Fusion modes a bank override may name."
  def fusion_modes, do: Map.keys(@fusion_modes)

  # Bank layer wins when it supplies a usable value; otherwise the global layer; otherwise
  # the default. An unusable bank value falls through rather than overriding with garbage.
  defp pick(global, bank, key, coerce, default) do
    with :error <- coerced(bank, key, coerce),
         :error <- coerced(global, key, coerce) do
      default
    else
      {:ok, value} -> value
    end
  end

  defp coerced(layer, key, coerce) do
    case fetch(layer, key) do
      {:ok, raw} -> coerce.(raw)
      :error -> :error
    end
  end

  defp fetch(layer, key) when is_list(layer) do
    if Keyword.keyword?(layer), do: Keyword.fetch(layer, key), else: :error
  end

  defp fetch(layer, key) when is_map(layer) do
    case Map.fetch(layer, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(layer, Atom.to_string(key))
    end
  end

  defp fetch(_layer, _key), do: :error

  defp coerce_mode(value) when is_atom(value) do
    if value in Map.values(@fusion_modes), do: {:ok, value}, else: :error
  end

  defp coerce_mode(value) when is_binary(value) do
    case Map.fetch(@fusion_modes, value) do
      {:ok, mode} -> {:ok, mode}
      :error -> :error
    end
  end

  defp coerce_mode(_value), do: :error

  defp coerce_normalization(value) when is_atom(value) do
    if value in Map.values(@normalizations), do: {:ok, value}, else: :error
  end

  defp coerce_normalization(value) when is_binary(value) do
    case Map.fetch(@normalizations, value) do
      {:ok, normalization} -> {:ok, normalization}
      :error -> :error
    end
  end

  defp coerce_normalization(_value), do: :error

  # RRF looks weights up by strategy name, which is a string on the item, so string keys
  # are the wire format. Atom keys (from app config) are converted to match.
  defp coerce_weights(value) when is_map(value) do
    weights =
      Enum.reduce(value, %{}, fn {arm, weight}, acc ->
        with {:ok, name} <- coerce_arm(arm),
             {:ok, number} <- coerce_number(weight) do
          Map.put(acc, name, number)
        else
          :error -> acc
        end
      end)

    {:ok, weights}
  end

  defp coerce_weights(_value), do: :error

  defp coerce_arm(arm) when is_binary(arm), do: {:ok, arm}
  defp coerce_arm(arm) when is_atom(arm), do: {:ok, Atom.to_string(arm)}
  defp coerce_arm(_arm), do: :error

  defp coerce_number(value) when is_float(value), do: {:ok, value}
  defp coerce_number(value) when is_integer(value), do: {:ok, value * 1.0}

  defp coerce_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp coerce_number(_value), do: :error
end
