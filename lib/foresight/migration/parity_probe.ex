defmodule Foresight.Migration.ParityProbe do
  @moduledoc false

  import Ecto.Query

  alias Foresight.Embeddings.Profile, as: EmbeddingProfile
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.Directive
  alias Foresight.Schemas.Document
  alias Foresight.Schemas.Entity
  alias Foresight.Schemas.EntityLink
  alias Foresight.Schemas.FileStorage
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Schemas.MemoryUnitEntity
  alias Foresight.Schemas.Webhook

  @default_repo Foresight.Repo
  @default_sample_size 10
  @default_cosine_threshold 0.99

  @spec probe_bank(String.t(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             bank_id: String.t(),
             bank_match?: boolean(),
             source_directive_count: non_neg_integer(),
             target_directive_count: non_neg_integer(),
             source_webhook_count: non_neg_integer(),
             target_webhook_count: non_neg_integer(),
             source_file_storage_count: non_neg_integer(),
             target_file_storage_count: non_neg_integer(),
             source_document_count: non_neg_integer(),
             target_document_count: non_neg_integer(),
             source_memory_unit_count: non_neg_integer(),
             target_memory_unit_count: non_neg_integer(),
             source_entity_count: non_neg_integer(),
             target_entity_count: non_neg_integer(),
             source_memory_unit_entity_count: non_neg_integer(),
             target_memory_unit_entity_count: non_neg_integer(),
             source_entity_link_count: non_neg_integer(),
             target_entity_link_count: non_neg_integer(),
             missing_file_storage_keys: [String.t()],
             extra_file_storage_keys: [String.t()],
             mismatched_file_storage_keys: [String.t()],
             missing_document_ids: [String.t()],
             extra_document_ids: [String.t()],
             mismatched_document_ids: [String.t()],
             missing_in_target: [String.t()],
             extra_in_target: [String.t()],
             mismatched_memory_unit_ids: [String.t()],
             missing_entity_ids: [String.t()],
             extra_entity_ids: [String.t()],
             mismatched_entity_ids: [String.t()],
             missing_directive_ids: [String.t()],
             extra_directive_ids: [String.t()],
             mismatched_directive_ids: [String.t()],
             missing_webhook_ids: [String.t()],
             extra_webhook_ids: [String.t()],
             mismatched_webhook_ids: [String.t()],
             missing_memory_unit_entities: [{String.t(), String.t()}],
             extra_memory_unit_entities: [{String.t(), String.t()}],
             missing_entity_links: [{String.t(), String.t(), String.t(), integer()}],
             extra_entity_links: [{String.t(), String.t(), String.t(), integer()}],
             eligible_memory_unit_count: non_neg_integer(),
             sampled_memory_unit_count: non_neg_integer(),
             sampled_memory_unit_ids: [String.t()],
             cosine_threshold: float(),
             minimum_cosine: float() | nil,
             cosine_failures: [map()],
             cosine_pass?: boolean(),
             clean?: boolean()
           }}
          | {:error, term()}
  def probe_bank(source_prefix, target_prefix, bank_id, opts \\ [])

  def probe_bank(source_prefix, target_prefix, bank_id, opts)
      when is_binary(source_prefix) and is_binary(target_prefix) and is_binary(bank_id) do
    repo = Keyword.get(opts, :repo, @default_repo)

    source_bank = repo.one(from(bank in Bank, where: bank.id == ^bank_id), prefix: source_prefix)
    target_bank = repo.one(from(bank in Bank, where: bank.id == ^bank_id), prefix: target_prefix)

    source_directives = fetch_directives(repo, source_prefix, bank_id)
    target_directives = fetch_directives(repo, target_prefix, bank_id)
    source_webhooks = fetch_webhooks(repo, source_prefix, bank_id)
    target_webhooks = fetch_webhooks(repo, target_prefix, bank_id)
    source_file_storage = fetch_file_storage(repo, source_prefix, bank_id)
    target_file_storage = fetch_file_storage(repo, target_prefix, bank_id)
    source_documents = fetch_documents(repo, source_prefix, bank_id)
    target_documents = fetch_documents(repo, target_prefix, bank_id)
    source_units = fetch_units(repo, source_prefix, bank_id)
    target_units = fetch_units(repo, target_prefix, bank_id)
    source_entities = fetch_entities(repo, source_prefix, bank_id)
    target_entities = fetch_entities(repo, target_prefix, bank_id)
    source_links = fetch_memory_unit_entities(repo, source_prefix, bank_id)
    target_links = fetch_memory_unit_entities(repo, target_prefix, bank_id)
    source_entity_links = fetch_entity_links(repo, source_prefix, bank_id)
    target_entity_links = fetch_entity_links(repo, target_prefix, bank_id)
    cosine_probe = run_cosine_probe(repo, target_prefix, bank_id, length(target_units), opts)

    source_directives_by_id = Map.new(source_directives, &{&1.id, comparable_directive(&1)})
    target_directives_by_id = Map.new(target_directives, &{&1.id, comparable_directive(&1)})
    source_webhooks_by_id = Map.new(source_webhooks, &{&1.id, comparable_webhook(&1)})
    target_webhooks_by_id = Map.new(target_webhooks, &{&1.id, comparable_webhook(&1)})

    source_file_storage_by_key =
      Map.new(source_file_storage, &{&1.storage_key, comparable_file_storage(&1)})

    target_file_storage_by_key =
      Map.new(target_file_storage, &{&1.storage_key, comparable_file_storage(&1)})

    source_documents_by_id = Map.new(source_documents, &{&1.external_id, comparable_document(&1)})
    target_documents_by_id = Map.new(target_documents, &{&1.external_id, comparable_document(&1)})
    source_by_id = Map.new(source_units, &{&1.id, comparable_unit(&1)})
    target_by_id = Map.new(target_units, &{&1.id, comparable_unit(&1)})
    source_entities_by_id = Map.new(source_entities, &{&1.id, comparable_entity(&1)})
    target_entities_by_id = Map.new(target_entities, &{&1.id, comparable_entity(&1)})

    source_directive_ids = MapSet.new(Map.keys(source_directives_by_id))
    target_directive_ids = MapSet.new(Map.keys(target_directives_by_id))
    source_webhook_ids = MapSet.new(Map.keys(source_webhooks_by_id))
    target_webhook_ids = MapSet.new(Map.keys(target_webhooks_by_id))
    source_file_storage_keys = MapSet.new(Map.keys(source_file_storage_by_key))
    target_file_storage_keys = MapSet.new(Map.keys(target_file_storage_by_key))
    source_document_ids = MapSet.new(Map.keys(source_documents_by_id))
    target_document_ids = MapSet.new(Map.keys(target_documents_by_id))
    source_ids = MapSet.new(Map.keys(source_by_id))
    target_ids = MapSet.new(Map.keys(target_by_id))
    source_entity_ids = MapSet.new(Map.keys(source_entities_by_id))
    target_entity_ids = MapSet.new(Map.keys(target_entities_by_id))
    source_link_set = MapSet.new(Enum.map(source_links, &comparable_memory_unit_entity/1))
    target_link_set = MapSet.new(Enum.map(target_links, &comparable_memory_unit_entity/1))
    source_entity_link_set = MapSet.new(Enum.map(source_entity_links, &comparable_entity_link/1))
    target_entity_link_set = MapSet.new(Enum.map(target_entity_links, &comparable_entity_link/1))

    missing_directive_ids =
      source_directive_ids
      |> MapSet.difference(target_directive_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    extra_directive_ids =
      target_directive_ids
      |> MapSet.difference(source_directive_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    missing_webhook_ids =
      source_webhook_ids
      |> MapSet.difference(target_webhook_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    extra_webhook_ids =
      target_webhook_ids
      |> MapSet.difference(source_webhook_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    missing_file_storage_keys =
      source_file_storage_keys
      |> MapSet.difference(target_file_storage_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    extra_file_storage_keys =
      target_file_storage_keys
      |> MapSet.difference(source_file_storage_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    missing_document_ids =
      source_document_ids
      |> MapSet.difference(target_document_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    extra_document_ids =
      target_document_ids
      |> MapSet.difference(source_document_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    missing_in_target =
      source_ids |> MapSet.difference(target_ids) |> MapSet.to_list() |> Enum.sort()

    extra_in_target =
      target_ids |> MapSet.difference(source_ids) |> MapSet.to_list() |> Enum.sort()

    missing_entity_ids =
      source_entity_ids |> MapSet.difference(target_entity_ids) |> MapSet.to_list() |> Enum.sort()

    extra_entity_ids =
      target_entity_ids |> MapSet.difference(source_entity_ids) |> MapSet.to_list() |> Enum.sort()

    missing_memory_unit_entities =
      source_link_set |> MapSet.difference(target_link_set) |> MapSet.to_list() |> Enum.sort()

    extra_memory_unit_entities =
      target_link_set |> MapSet.difference(source_link_set) |> MapSet.to_list() |> Enum.sort()

    missing_entity_links =
      source_entity_link_set
      |> MapSet.difference(target_entity_link_set)
      |> MapSet.to_list()
      |> Enum.sort()

    extra_entity_links =
      target_entity_link_set
      |> MapSet.difference(source_entity_link_set)
      |> MapSet.to_list()
      |> Enum.sort()

    shared_directive_ids =
      source_directive_ids
      |> MapSet.intersection(target_directive_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    mismatched_directive_ids =
      Enum.filter(shared_directive_ids, fn id ->
        Map.fetch!(source_directives_by_id, id) != Map.fetch!(target_directives_by_id, id)
      end)

    shared_webhook_ids =
      source_webhook_ids
      |> MapSet.intersection(target_webhook_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    mismatched_webhook_ids =
      Enum.filter(shared_webhook_ids, fn id ->
        Map.fetch!(source_webhooks_by_id, id) != Map.fetch!(target_webhooks_by_id, id)
      end)

    shared_file_storage_keys =
      source_file_storage_keys
      |> MapSet.intersection(target_file_storage_keys)
      |> MapSet.to_list()
      |> Enum.sort()

    mismatched_file_storage_keys =
      Enum.filter(shared_file_storage_keys, fn key ->
        Map.fetch!(source_file_storage_by_key, key) != Map.fetch!(target_file_storage_by_key, key)
      end)

    shared_document_ids =
      source_document_ids
      |> MapSet.intersection(target_document_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    mismatched_document_ids =
      Enum.filter(shared_document_ids, fn id ->
        Map.fetch!(source_documents_by_id, id) != Map.fetch!(target_documents_by_id, id)
      end)

    shared_ids =
      source_ids
      |> MapSet.intersection(target_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    mismatched_memory_unit_ids =
      Enum.filter(shared_ids, fn id ->
        Map.fetch!(source_by_id, id) != Map.fetch!(target_by_id, id)
      end)

    shared_entity_ids =
      source_entity_ids
      |> MapSet.intersection(target_entity_ids)
      |> MapSet.to_list()
      |> Enum.sort()

    mismatched_entity_ids =
      Enum.filter(shared_entity_ids, fn id ->
        Map.fetch!(source_entities_by_id, id) != Map.fetch!(target_entities_by_id, id)
      end)

    bank_match? = comparable_bank(source_bank) == comparable_bank(target_bank)

    {:ok,
     %{
       bank_id: bank_id,
       bank_match?: bank_match?,
       source_directive_count: map_size(source_directives_by_id),
       target_directive_count: map_size(target_directives_by_id),
       source_webhook_count: map_size(source_webhooks_by_id),
       target_webhook_count: map_size(target_webhooks_by_id),
       source_file_storage_count: map_size(source_file_storage_by_key),
       target_file_storage_count: map_size(target_file_storage_by_key),
       source_document_count: map_size(source_documents_by_id),
       target_document_count: map_size(target_documents_by_id),
       source_memory_unit_count: map_size(source_by_id),
       target_memory_unit_count: map_size(target_by_id),
       source_entity_count: map_size(source_entities_by_id),
       target_entity_count: map_size(target_entities_by_id),
       source_memory_unit_entity_count: MapSet.size(source_link_set),
       target_memory_unit_entity_count: MapSet.size(target_link_set),
       source_entity_link_count: MapSet.size(source_entity_link_set),
       target_entity_link_count: MapSet.size(target_entity_link_set),
       missing_file_storage_keys: missing_file_storage_keys,
       extra_file_storage_keys: extra_file_storage_keys,
       mismatched_file_storage_keys: mismatched_file_storage_keys,
       missing_document_ids: missing_document_ids,
       extra_document_ids: extra_document_ids,
       mismatched_document_ids: mismatched_document_ids,
       missing_in_target: missing_in_target,
       extra_in_target: extra_in_target,
       mismatched_memory_unit_ids: mismatched_memory_unit_ids,
       missing_entity_ids: missing_entity_ids,
       extra_entity_ids: extra_entity_ids,
       mismatched_entity_ids: mismatched_entity_ids,
       missing_directive_ids: missing_directive_ids,
       extra_directive_ids: extra_directive_ids,
       mismatched_directive_ids: mismatched_directive_ids,
       missing_webhook_ids: missing_webhook_ids,
       extra_webhook_ids: extra_webhook_ids,
       mismatched_webhook_ids: mismatched_webhook_ids,
       missing_memory_unit_entities: missing_memory_unit_entities,
       extra_memory_unit_entities: extra_memory_unit_entities,
       missing_entity_links: missing_entity_links,
       extra_entity_links: extra_entity_links,
       eligible_memory_unit_count: cosine_probe.eligible_memory_unit_count,
       sampled_memory_unit_count: cosine_probe.sampled_memory_unit_count,
       sampled_memory_unit_ids: cosine_probe.sampled_memory_unit_ids,
       cosine_threshold: cosine_probe.cosine_threshold,
       minimum_cosine: cosine_probe.minimum_cosine,
       cosine_failures: cosine_probe.cosine_failures,
       cosine_pass?: cosine_probe.cosine_pass?,
       clean?:
         bank_match? and missing_directive_ids == [] and extra_directive_ids == [] and
           mismatched_directive_ids == [] and missing_webhook_ids == [] and
           extra_webhook_ids == [] and
           mismatched_webhook_ids == [] and missing_file_storage_keys == [] and
           extra_file_storage_keys == [] and
           mismatched_file_storage_keys == [] and missing_document_ids == [] and
           extra_document_ids == [] and
           mismatched_document_ids == [] and missing_in_target == [] and extra_in_target == [] and
           mismatched_memory_unit_ids == [] and missing_entity_ids == [] and
           extra_entity_ids == [] and
           mismatched_entity_ids == [] and missing_memory_unit_entities == [] and
           extra_memory_unit_entities == [] and missing_entity_links == [] and
           extra_entity_links == [] and cosine_probe.cosine_pass?
     }}
  end

  def probe_bank(_source_prefix, _target_prefix, _bank_id, _opts), do: {:error, :invalid_prefix}

  defp fetch_directives(repo, prefix, bank_id) do
    repo.all(from(directive in Directive, where: directive.bank_id == ^bank_id), prefix: prefix)
  end

  defp fetch_webhooks(repo, prefix, bank_id) do
    repo.all(from(webhook in Webhook, where: webhook.bank_id == ^bank_id), prefix: prefix)
  end

  defp fetch_file_storage(repo, prefix, bank_id) do
    repo.all(
      from(fs in FileStorage,
        join: document in Document,
        on: document.file_storage_key == fs.storage_key,
        where:
          document.bank_id == ^bank_id and not is_nil(document.file_storage_key) and
            document.file_storage_key != ""
      ),
      prefix: prefix
    )
  end

  defp fetch_documents(repo, prefix, bank_id) do
    repo.all(from(document in Document, where: document.bank_id == ^bank_id), prefix: prefix)
  end

  defp fetch_units(repo, prefix, bank_id) do
    repo.all(from(unit in MemoryUnit, where: unit.bank_id == ^bank_id), prefix: prefix)
  end

  defp fetch_probe_units(repo, prefix, bank_id, sample_size) do
    repo.all(
      from(unit in MemoryUnit,
        where:
          unit.bank_id == ^bank_id and unit.embedded_dim in [384, 1024] and unit.content != "" and
            ((unit.embedded_dim == 384 and not is_nil(unit.embedding_384)) or
               (unit.embedded_dim == 1024 and not is_nil(unit.embedding_1024))),
        order_by: [asc_nulls_last: unit.mentioned_at, asc: unit.id],
        limit: ^sample_size,
        select: %{
          id: unit.id,
          content: unit.content,
          embedded_dim: unit.embedded_dim,
          embedded_by: unit.embedded_by,
          embedding_384: unit.embedding_384,
          embedding_1024: unit.embedding_1024
        }
      ),
      prefix: prefix
    )
  end

  defp count_probe_units(repo, prefix, bank_id) do
    repo.aggregate(
      from(unit in MemoryUnit,
        where:
          unit.bank_id == ^bank_id and unit.embedded_dim in [384, 1024] and unit.content != "" and
            ((unit.embedded_dim == 384 and not is_nil(unit.embedding_384)) or
               (unit.embedded_dim == 1024 and not is_nil(unit.embedding_1024)))
      ),
      :count,
      :id,
      prefix: prefix
    )
  end

  defp fetch_entities(repo, prefix, bank_id) do
    repo.all(from(entity in Entity, where: entity.bank_id == ^bank_id), prefix: prefix)
  end

  defp fetch_memory_unit_entities(repo, prefix, bank_id) do
    repo.all(
      from(link in MemoryUnitEntity,
        join: unit in MemoryUnit,
        on: unit.id == link.memory_unit_id,
        join: entity in Entity,
        on: entity.id == link.entity_id,
        where: unit.bank_id == ^bank_id and entity.bank_id == ^bank_id
      ),
      prefix: prefix
    )
  end

  defp fetch_entity_links(repo, prefix, bank_id) do
    repo.all(from(link in EntityLink, where: link.bank_id == ^bank_id), prefix: prefix)
  end

  defp comparable_bank(nil), do: nil

  defp comparable_bank(bank) do
    %{
      id: bank.id,
      name: bank.name,
      mission: bank.mission,
      background: bank.background,
      disposition: bank.disposition,
      auto_consolidate: bank.auto_consolidate
    }
  end

  defp comparable_file_storage(file_storage) do
    %{
      storage_key: file_storage.storage_key,
      data: file_storage.data
    }
  end

  defp comparable_directive(directive) do
    %{
      id: directive.id,
      bank_id: directive.bank_id,
      name: directive.name,
      content: directive.content,
      priority: directive.priority,
      is_active: directive.is_active,
      tags: directive.tags,
      metadata: directive.metadata
    }
  end

  defp comparable_webhook(webhook) do
    %{
      id: webhook.id,
      bank_id: webhook.bank_id,
      url: webhook.url,
      secret: webhook.secret,
      event_types: webhook.event_types,
      enabled: webhook.enabled
    }
  end

  defp comparable_document(document) do
    %{
      external_id: document.external_id,
      title: document.title,
      original_text: document.original_text,
      content_hash: document.content_hash,
      file_storage_key: document.file_storage_key,
      file_original_name: document.file_original_name,
      file_content_type: document.file_content_type,
      tags: document.tags,
      metadata: document.metadata
    }
  end

  defp comparable_unit(unit) do
    %{
      id: unit.id,
      bank_id: unit.bank_id,
      fact_type: unit.fact_type,
      content: unit.content,
      context: unit.context,
      tags: unit.tags,
      metadata: unit.metadata,
      proof_count: unit.proof_count,
      source_memory_ids: unit.source_memory_ids,
      embedded_by: unit.embedded_by,
      embedded_dim: unit.embedded_dim,
      embedding_384: vector_to_list(unit.embedding_384),
      embedding_1024: vector_to_list(unit.embedding_1024),
      document_ref: unit.document_ref,
      occurred_at: unit.occurred_at,
      occurred_start: unit.occurred_start,
      occurred_end: unit.occurred_end,
      mentioned_at: unit.mentioned_at,
      observation_scopes: unit.observation_scopes,
      text_signals: unit.text_signals,
      consolidated_at: unit.consolidated_at,
      consolidation_failed_at: unit.consolidation_failed_at
    }
  end

  defp comparable_entity(entity) do
    %{
      id: entity.id,
      bank_id: entity.bank_id,
      canonical_name: entity.canonical_name,
      normalized_name: entity.normalized_name,
      mention_count: entity.mention_count,
      first_seen: entity.first_seen,
      last_seen: entity.last_seen
    }
  end

  defp comparable_memory_unit_entity(link) do
    {link.memory_unit_id, link.entity_id}
  end

  defp comparable_entity_link(link) do
    {link.source_entity_id, link.target_entity_id, link.link_type, link.weight}
  end

  defp run_cosine_probe(repo, target_prefix, bank_id, total_memory_unit_count, opts) do
    cosine_threshold = Keyword.get(opts, :cosine_threshold, @default_cosine_threshold)
    sample_size = Keyword.get(opts, :sample_size, @default_sample_size)
    eligible_memory_unit_count = count_probe_units(repo, target_prefix, bank_id)
    units = fetch_probe_units(repo, target_prefix, bank_id, sample_size)
    embedder = probe_embedder(opts)

    cond do
      eligible_memory_unit_count == 0 and total_memory_unit_count == 0 ->
        %{
          eligible_memory_unit_count: 0,
          sampled_memory_unit_count: 0,
          sampled_memory_unit_ids: [],
          cosine_threshold: cosine_threshold,
          minimum_cosine: nil,
          cosine_failures: [],
          cosine_pass?: true
        }

      eligible_memory_unit_count == 0 ->
        %{
          eligible_memory_unit_count: 0,
          sampled_memory_unit_count: 0,
          sampled_memory_unit_ids: [],
          cosine_threshold: cosine_threshold,
          minimum_cosine: nil,
          cosine_failures: [%{reason: "no_eligible_vectors"}],
          cosine_pass?: false
        }

      true ->
        probe_cosine_vectors(units, embedder, cosine_threshold)
        |> Map.put(:eligible_memory_unit_count, eligible_memory_unit_count)
    end
  end

  defp probe_cosine_vectors(units, embedder, cosine_threshold) do
    {results, failures} =
      Enum.map_reduce(units, [], fn unit, failures ->
        case embedder.embed(unit.content,
               model_id: unit.embedded_by,
               embedding_dim: unit.embedded_dim
             ) do
          {:ok, query_embedding} ->
            cosine =
              cosine_similarity(
                vector_to_list(EmbeddingProfile.vector(unit)),
                query_embedding
              )

            result = %{memory_unit_id: unit.id, cosine: cosine}

            failures =
              if cosine >= cosine_threshold do
                failures
              else
                [Map.put(result, :threshold, cosine_threshold) | failures]
              end

            {result, failures}

          {:error, reason} ->
            failure = %{memory_unit_id: unit.id, reason: inspect(reason)}
            {failure, [failure | failures]}
        end
      end)

    minimum_cosine =
      results
      |> Enum.map(&Map.get(&1, :cosine))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        cosines -> Enum.min(cosines)
      end

    %{
      sampled_memory_unit_count: length(units),
      sampled_memory_unit_ids: Enum.map(units, & &1.id),
      cosine_threshold: cosine_threshold,
      minimum_cosine: minimum_cosine,
      cosine_failures: Enum.reverse(failures),
      cosine_pass?: failures == []
    }
  end

  defp probe_embedder(opts) do
    Keyword.get_lazy(opts, :embedder, fn ->
      Foresight.Config.get(:engine, :embedder, Foresight.Embedders.Noop)
    end)
  end

  defp cosine_similarity(left, right) when is_list(left) and is_list(right) do
    numerator =
      Enum.zip(left, right)
      |> Enum.reduce(0.0, fn {lhs, rhs}, acc -> acc + lhs * rhs end)

    left_norm = :math.sqrt(Enum.reduce(left, 0.0, fn value, acc -> acc + value * value end))
    right_norm = :math.sqrt(Enum.reduce(right, 0.0, fn value, acc -> acc + value * value end))

    if left_norm == 0.0 or right_norm == 0.0 do
      0.0
    else
      numerator / (left_norm * right_norm)
    end
  end

  defp vector_to_list(nil), do: nil
  defp vector_to_list(vector), do: Pgvector.to_list(vector)
end
