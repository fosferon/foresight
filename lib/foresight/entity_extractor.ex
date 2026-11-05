defmodule Foresight.EntityExtractor do
  @moduledoc """
  Seam for deriving entity names from raw content.

  This is the FALLBACK path only. When retain-time atomic-fact extraction is on,
  each fact already carries LLM-extracted entities that are threaded
  through to `materialize_entities`, mirroring Hindsight's `fact.entities` source
  (`engine/retain/entity_processing.py:32`). The extractor is invoked only when an
  item has no such entities — extraction is off, or entities are being rebuilt from
  stored content.

  The default implementation is Foresight.EntityExtractors.Simple (a crude regex);
  the module is selected via the engine `:entity_extractor` config so it can be
  swapped without touching the storage layer.

  An extractor may optionally implement `extract/2` to receive the retain opts
  (`:llm`, `:provider`, `:provider_opts`, `:sleep_ms`) — `Foresight.EntityExtractors.LLM`
  needs the LLM handle. `run/3` dispatches to `extract/2` when present and otherwise to
  the pure `extract/1`, mirroring the `function_exported?` optional-callback dispatch
  used elsewhere (Foresight.LLM.supports_tool_calling?/1).
  """

  @doc "Return the entity names found in `content` (deduplicated)."
  @callback extract(content :: String.t()) :: [String.t()]

  @doc "Like `extract/1` but with access to the retain opts (e.g. an `:llm` handle)."
  @callback extract(content :: String.t(), opts :: keyword()) :: [String.t()]

  @optional_callbacks extract: 2

  @doc """
  Invoke `extractor` on `content`, passing `opts` when the module implements the
  optional `extract/2`; otherwise the pure `extract/1`. `opts` is ignored by the
  latter.
  """
  @spec run(module(), String.t(), keyword()) :: [String.t()]
  def run(extractor, content, opts \\ [])
      when is_atom(extractor) and is_binary(content) and is_list(opts) do
    if Code.ensure_loaded?(extractor) and function_exported?(extractor, :extract, 2) do
      extractor.extract(content, opts)
    else
      extractor.extract(content)
    end
  end
end
