defmodule Foresight.Migration.SourceDrop do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Foresight.Schemas.Bank
  alias Foresight.Schemas.Directive
  alias Foresight.Schemas.Document
  alias Foresight.Schemas.Entity
  alias Foresight.Schemas.EntityLink
  alias Foresight.Schemas.MemoryUnit
  alias Foresight.Schemas.Webhook

  @default_repo Foresight.Repo

  @spec drop_bank(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def drop_bank(source_prefix, bank_id, opts \\ [])

  def drop_bank(source_prefix, bank_id, opts)
      when is_binary(source_prefix) and is_binary(bank_id) do
    repo = Keyword.get(opts, :repo, @default_repo)

    repo.transaction(fn ->
      storage_keys = source_storage_keys(repo, source_prefix, bank_id)

      deleted_memory_unit_entities =
        delete_memory_unit_entities(repo, source_prefix, bank_id)

      deleted_entity_links =
        from(link in EntityLink, where: link.bank_id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      deleted_directives =
        from(directive in Directive, where: directive.bank_id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      deleted_webhooks =
        from(webhook in Webhook, where: webhook.bank_id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      deleted_memory_units =
        from(unit in MemoryUnit, where: unit.bank_id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      deleted_entities =
        from(entity in Entity, where: entity.bank_id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      deleted_documents =
        from(document in Document, where: document.bank_id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      deleted_file_storage = delete_orphaned_file_storage(repo, source_prefix, storage_keys)

      deleted_banks =
        from(bank in Bank, where: bank.id == ^bank_id)
        |> repo.delete_all(prefix: source_prefix)
        |> elem(0)

      %{
        source_prefix: source_prefix,
        bank_id: bank_id,
        deleted_banks: deleted_banks,
        deleted_directives: deleted_directives,
        deleted_webhooks: deleted_webhooks,
        deleted_file_storage: deleted_file_storage,
        deleted_documents: deleted_documents,
        deleted_memory_units: deleted_memory_units,
        deleted_entities: deleted_entities,
        deleted_memory_unit_entities: deleted_memory_unit_entities,
        deleted_entity_links: deleted_entity_links
      }
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def drop_bank(_source_prefix, _bank_id, _opts), do: {:error, :invalid_prefix}

  defp source_storage_keys(repo, source_prefix, bank_id) do
    from(document in Document,
      where:
        document.bank_id == ^bank_id and not is_nil(document.file_storage_key) and
          document.file_storage_key != "",
      select: document.file_storage_key
    )
    |> repo.all(prefix: source_prefix)
  end

  defp delete_memory_unit_entities(repo, source_prefix, bank_id) do
    assert_delete_count!(
      repo,
      """
      DELETE FROM "#{source_prefix}".memory_unit_entities AS mue
      USING "#{source_prefix}".memory_units AS mu
      WHERE mue.memory_unit_id = mu.id
        AND mu.bank_id = $1
      """,
      [bank_id]
    )
  end

  defp delete_orphaned_file_storage(_repo, _source_prefix, []), do: 0

  defp delete_orphaned_file_storage(repo, source_prefix, storage_keys) do
    assert_delete_count!(
      repo,
      """
      DELETE FROM "#{source_prefix}".file_storage AS fs
      WHERE fs.storage_key = ANY($1::text[])
        AND NOT EXISTS (
          SELECT 1
          FROM "#{source_prefix}".documents AS doc
          WHERE doc.file_storage_key = fs.storage_key
        )
      """,
      [storage_keys]
    )
  end

  defp assert_delete_count!(repo, sql, params) do
    case SQL.query(repo, sql, params) do
      {:ok, %{num_rows: count}} -> count
      {:error, reason} -> repo.rollback(reason)
    end
  end
end
