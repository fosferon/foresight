defmodule Foresight.Reflect.MentalModels do
  @moduledoc """
  Mental models for reflect, at parity with Hindsight: ranked by embedding
  similarity to the query, capped, and reported with a per-model staleness verdict.

  Mental models are documents (`metadata.document_type = "mental_model"`). Their
  embeddings live in `mental_model_embeddings` and are kept current lazily: before a
  search the models whose content, dimension or model no longer match their stored
  row are re-embedded under the bank's embedding profile, so curated models that
  predate this table get indexed on first use and a profile change re-indexes them.

  A model is stale when a memory in its scope was written after
  `last_refreshed_at`. The scope is the model's tags under `trigger.tags_match`
  (`any` | `all` | `any_strict` | `all_strict`, the recall semantics; the
  non-strict modes also admit untagged memories) and `trigger.fact_types` when set.
  An untagged model is global and any new memory makes it stale. A model never
  refreshed is stale by definition.
  """

  import Ecto.Query

  alias Foresight.Embeddings.Profile, as: EmbeddingProfile
  alias Foresight.Reflect.MentalModelRanking
  alias Foresight.Schemas.Document
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Schemas.MentalModelEmbedding

  @max_embed_per_call 50
  @fact_types ~w(world experience observation)

  @type staleness :: {boolean(), String.t() | nil}

  @doc """
  Rank `documents` for `query`, embed the stragglers first, and return at most
  `limit` tool entries (Hindsight's `tool_search_mental_models` shape plus the
  `title`/`text` keys older callers read). Without a usable profile or query the
  lexical ranking stands in, with `relevance` absent.
  """
  @spec search(module(), String.t(), [struct()], String.t(), pos_integer(), keyword()) ::
          [map()]
  def search(repo, bank_id, documents, query, limit, opts) do
    repo_opts = Keyword.get(opts, :repo_opts, [])
    profile = Keyword.get(opts, :profile)
    embedder = Keyword.get(opts, :embedder)

    if is_map(profile) and is_atom(embedder) and not is_nil(embedder) do
      ensure_embeddings(repo, bank_id, documents, profile, embedder, repo_opts)
    end

    repo
    |> rank(bank_id, documents, query, limit, profile, embedder, repo_opts)
    |> Enum.map(fn {document, relevance} ->
      entry(document, relevance, stale?(repo, bank_id, document, repo_opts))
    end)
  end

  @doc "Embed (or re-embed) every model whose stored embedding is missing or outdated."
  @spec ensure_embeddings(module(), String.t(), [struct()], map(), module(), keyword()) :: :ok
  def ensure_embeddings(repo, bank_id, documents, profile, embedder, repo_opts) do
    candidates =
      documents
      |> Enum.filter(&embeddable?/1)
      |> Enum.take(@max_embed_per_call)

    ids = Enum.map(candidates, & &1.id)

    existing =
      if ids == [] do
        %{}
      else
        from(row in MentalModelEmbedding, where: row.document_id in ^ids)
        |> repo.all(repo_opts)
        |> Map.new(&{&1.document_id, &1})
      end

    Enum.each(candidates, fn document ->
      hash = content_hash(document)

      if outdated?(Map.get(existing, document.id), hash, profile) do
        embed_and_store(repo, bank_id, document, hash, profile, embedder, repo_opts)
      end
    end)

    :ok
  end

  @doc """
  Order `documents` by cosine similarity of their stored embedding to `query`, most
  similar first, models without a comparable embedding last. Falls back to lexical
  ranking when the query is blank, the profile is unknown or the query cannot be
  embedded. Returns `{document, relevance | nil}` pairs, at most `limit`.
  """
  @spec rank(
          module(),
          String.t(),
          [struct()],
          String.t(),
          pos_integer(),
          map() | nil,
          module() | nil,
          keyword()
        ) ::
          [{struct(), float() | nil}]
  def rank(repo, _bank_id, documents, query, limit, profile, embedder, repo_opts) do
    with true <- is_binary(query) and String.trim(query) != "",
         %{"embedding_dim" => dim} <- profile,
         true <- is_atom(embedder) and not is_nil(embedder),
         {:ok, query_embedding} <- embedder.embed(query, EmbeddingProfile.embedder_opts(profile)),
         ids = Enum.map(documents, & &1.id),
         true <- ids != [] do
      query_vector = Pgvector.new(query_embedding)

      scores =
        from(row in MentalModelEmbedding,
          where: row.document_id in ^ids and row.embedded_dim == ^dim,
          select:
            {row.document_id, fragment("1 - (? <=> ?::vector)", row.embedding, ^query_vector)}
        )
        |> repo.all(repo_opts)
        |> Map.new()

      documents
      |> Enum.map(&{&1, Map.get(scores, &1.id)})
      |> Enum.sort_by(fn {document, score} -> {-(score || -1.0), document.external_id} end)
      |> Enum.take(limit)
      |> Enum.map(fn {document, score} -> {document, round_relevance(score)} end)
    else
      _ ->
        documents
        |> MentalModelRanking.rank(query, limit)
        |> Enum.map(&{&1, nil})
    end
  end

  @doc "Whether new in-scope memories arrived since the model's last refresh, with the reason."
  @spec stale?(module(), String.t(), struct(), keyword()) :: staleness()
  def stale?(repo, bank_id, %Document{} = document, repo_opts) do
    metadata = document.metadata || %{}

    case parse_datetime(metadata["last_refreshed_at"]) do
      nil ->
        {true, "never refreshed"}

      since ->
        trigger = if(is_map(metadata["trigger"]), do: metadata["trigger"], else: %{})

        query =
          from(unit in MemoryUnit,
            where: unit.bank_id == ^bank_id and unit.updated_at > ^since
          )
          |> scope_fact_types(trigger["fact_types"])
          |> scope_tags(document.tags || [], trigger["tags_match"] || "any")

        if repo.exists?(query, repo_opts) do
          {true, "new in-scope memories ingested since last refresh"}
        else
          {false, nil}
        end
    end
  end

  @doc "The tool/result entry for one ranked model."
  @spec entry(struct(), float() | nil, staleness()) :: map()
  def entry(%Document{} = document, relevance, {stale?, reason}) do
    metadata = document.metadata || %{}

    %{
      "id" => to_string(document.external_id || document.id),
      "name" => document.title,
      "title" => document.title,
      "content" => document.original_text,
      "text" => document.original_text,
      "tags" => document.tags || [],
      "relevance" => relevance,
      "updated_at" => metadata["last_refreshed_at"],
      "is_stale" => stale?,
      "staleness_reason" => reason
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # ---- embeddings --------------------------------------------------------------

  defp embeddable?(%Document{original_text: text}) when is_binary(text),
    do: String.trim(text) != ""

  defp embeddable?(_document), do: false

  defp outdated?(nil, _hash, _profile), do: true

  defp outdated?(%MentalModelEmbedding{} = row, hash, profile) do
    row.content_hash != hash or row.embedded_dim != profile["embedding_dim"] or
      row.embedded_model != profile["model_id"]
  end

  defp embed_and_store(repo, bank_id, document, hash, profile, embedder, repo_opts) do
    case embedder.embed(embed_text(document), EmbeddingProfile.embedder_opts(profile)) do
      {:ok, values} when is_list(values) and values != [] ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        %MentalModelEmbedding{
          document_id: document.id,
          bank_id: bank_id,
          embedded_dim: profile["embedding_dim"],
          embedded_model: profile["model_id"],
          content_hash: hash,
          embedding: Pgvector.new(values),
          inserted_at: now,
          updated_at: now
        }
        |> repo.insert(
          Keyword.merge(repo_opts,
            on_conflict:
              {:replace,
               [:bank_id, :embedded_dim, :embedded_model, :content_hash, :embedding, :updated_at]},
            conflict_target: [:document_id]
          )
        )

        :ok

      _other ->
        # A failed embedding leaves the model lexically searchable; nothing to write.
        :ok
    end
  rescue
    _error -> :ok
  end

  # The synthesized content is what a query should match; the name is a label.
  defp embed_text(%Document{original_text: text}), do: text

  defp content_hash(%Document{} = document) do
    :crypto.hash(:sha256, "#{document.title}\n#{document.original_text}")
    |> Base.encode16(case: :lower)
  end

  defp round_relevance(nil), do: nil
  defp round_relevance(score) when is_number(score), do: Float.round(score * 1.0, 4)

  # ---- staleness scope ---------------------------------------------------------

  defp scope_fact_types(query, types) when is_list(types) and types != [] do
    atoms =
      types
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @fact_types))
      |> Enum.map(&String.to_existing_atom/1)

    if atoms == [], do: query, else: where(query, [unit], unit.fact_type in ^atoms)
  end

  defp scope_fact_types(query, _types), do: query

  defp scope_tags(query, [], _mode), do: query

  defp scope_tags(query, tags, mode) do
    tags = Enum.map(tags, &to_string/1)

    case to_string(mode) do
      "all_strict" ->
        where(query, [unit], fragment("? @> ?::text[]", unit.tags, ^tags))

      "all" ->
        where(
          query,
          [unit],
          fragment("cardinality(?) = 0", unit.tags) or
            fragment("? @> ?::text[]", unit.tags, ^tags)
        )

      "any_strict" ->
        where(query, [unit], fragment("? && ?::text[]", unit.tags, ^tags))

      _any ->
        where(
          query,
          [unit],
          fragment("cardinality(?) = 0", unit.tags) or
            fragment("? && ?::text[]", unit.tags, ^tags)
        )
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
