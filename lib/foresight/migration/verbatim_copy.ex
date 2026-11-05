defmodule Foresight.Migration.VerbatimCopy do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Foresight.Migration.EmbeddingAudit

  @default_repo Foresight.Repo
  @schema_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @spec copy_bank(String.t(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             bank_id: String.t(),
             copied_banks: non_neg_integer(),
             copied_directives: non_neg_integer(),
             copied_webhooks: non_neg_integer(),
             copied_file_storage: non_neg_integer(),
             copied_documents: non_neg_integer(),
             copied_memory_units: non_neg_integer(),
             copied_entities: non_neg_integer(),
             copied_memory_unit_entities: non_neg_integer(),
             copied_entity_links: non_neg_integer()
           }}
          | {:error, term()}
  def copy_bank(source_prefix, target_prefix, bank_id, opts \\ [])

  def copy_bank(source_prefix, target_prefix, bank_id, opts)
      when is_binary(source_prefix) and is_binary(target_prefix) and is_binary(bank_id) do
    repo = Keyword.get(opts, :repo, @default_repo)

    with :ok <- validate_prefix(source_prefix),
         :ok <- validate_prefix(target_prefix),
         {:ok, %{compatible?: true}} <-
           EmbeddingAudit.audit_schema(source_prefix, repo: repo, bank_id: bank_id),
         :ok <- audit_dependency_completeness(repo, source_prefix, bank_id),
         :ok <- audit_memory_unit_embedding_rows(repo, source_prefix, target_prefix, bank_id),
         {:ok, copied_banks, copied_directives, copied_webhooks, copied_file_storage,
          copied_documents, copied_memory_units, copied_entities, copied_memory_unit_entities,
          copied_entity_links} <-
           copy_rows(repo, source_prefix, target_prefix, bank_id) do
      {:ok,
       %{
         bank_id: bank_id,
         copied_banks: copied_banks,
         copied_directives: copied_directives,
         copied_webhooks: copied_webhooks,
         copied_file_storage: copied_file_storage,
         copied_documents: copied_documents,
         copied_memory_units: copied_memory_units,
         copied_entities: copied_entities,
         copied_memory_unit_entities: copied_memory_unit_entities,
         copied_entity_links: copied_entity_links
       }}
    else
      {:ok, %{compatible?: false} = audit} ->
        {:error, {:incompatible_embedding_dimensions, audit}}

      error ->
        error
    end
  end

  def copy_bank(_source_prefix, _target_prefix, _bank_id, _opts), do: {:error, :invalid_prefix}

  defp copy_rows(repo, source_prefix, target_prefix, bank_id) do
    repo.transaction(fn ->
      :ok = reassign_target_owners(repo, target_prefix)

      copied_banks =
        copy_banks(repo, source_prefix, target_prefix, bank_id)

      copied_directives =
        copy_directives(repo, source_prefix, target_prefix, bank_id)

      copied_webhooks =
        copy_webhooks(repo, source_prefix, target_prefix, bank_id)

      copied_file_storage =
        copy_file_storage(repo, source_prefix, target_prefix, bank_id)

      copied_documents =
        copy_documents(repo, source_prefix, target_prefix, bank_id)

      copied_memory_units =
        copy_memory_units(repo, source_prefix, target_prefix, bank_id)

      copied_entities =
        copy_entities(repo, source_prefix, target_prefix, bank_id)

      copied_memory_unit_entities =
        copy_memory_unit_entities(repo, source_prefix, target_prefix, bank_id)

      copied_entity_links =
        copy_entity_links(repo, source_prefix, target_prefix, bank_id)

      {copied_banks, copied_directives, copied_webhooks, copied_file_storage, copied_documents,
       copied_memory_units, copied_entities, copied_memory_unit_entities, copied_entity_links}
    end)
    |> case do
      {:ok,
       {copied_banks, copied_directives, copied_webhooks, copied_file_storage, copied_documents,
        copied_memory_units, copied_entities, copied_memory_unit_entities, copied_entity_links}} ->
        {:ok, copied_banks, copied_directives, copied_webhooks, copied_file_storage,
         copied_documents, copied_memory_units, copied_entities, copied_memory_unit_entities,
         copied_entity_links}

      error ->
        error
    end
  end

  defp audit_dependency_completeness(repo, source_prefix, bank_id) do
    with :ok <- audit_document_reference_completeness(repo, source_prefix, bank_id),
         :ok <- audit_file_storage_completeness(repo, source_prefix, bank_id),
         :ok <- audit_memory_unit_entity_completeness(repo, source_prefix, bank_id),
         :ok <- audit_entity_link_completeness(repo, source_prefix, bank_id) do
      :ok
    end
  end

  defp audit_document_reference_completeness(repo, source_prefix, bank_id) do
    {:ok, %{rows: [[total, eligible]]}} =
      SQL.query(
        repo,
        """
        SELECT
          COUNT(*)::bigint,
          COUNT(*) FILTER (
            WHERE mu.document_ref IS NULL
               OR (
                 doc.external_id IS NOT NULL
                 AND doc.bank_id = $1
               )
          )::bigint
        FROM "#{source_prefix}".memory_units AS mu
        LEFT JOIN "#{source_prefix}".documents AS doc
          ON doc.external_id = mu.document_ref
         AND doc.bank_id = mu.bank_id
        WHERE mu.bank_id = $1
        """,
        [bank_id]
      )

    if total == eligible do
      :ok
    else
      {:error,
       {:incomplete_dependent_rows,
        %{
          bank_id: bank_id,
          dependency: :document_refs,
          total_rows: total,
          eligible_rows: eligible
        }}}
    end
  end

  defp audit_memory_unit_entity_completeness(repo, source_prefix, bank_id) do
    {:ok, %{rows: [[total, eligible]]}} =
      SQL.query(
        repo,
        """
        SELECT
          COUNT(*)::bigint,
          COUNT(*) FILTER (WHERE mu.bank_id = $1 AND e.bank_id = $1)::bigint
        FROM "#{source_prefix}".memory_unit_entities AS mue
        INNER JOIN "#{source_prefix}".memory_units AS mu
          ON mu.id = mue.memory_unit_id
        INNER JOIN "#{source_prefix}".entities AS e
          ON e.id = mue.entity_id
        WHERE mu.bank_id = $1
           OR e.bank_id = $1
        """,
        [bank_id]
      )

    if total == eligible do
      :ok
    else
      {:error,
       {:incomplete_dependent_rows,
        %{
          bank_id: bank_id,
          dependency: :memory_unit_entities,
          total_rows: total,
          eligible_rows: eligible
        }}}
    end
  end

  defp audit_entity_link_completeness(repo, source_prefix, bank_id) do
    {:ok, %{rows: [[total, eligible]]}} =
      SQL.query(
        repo,
        """
        SELECT
          COUNT(*)::bigint,
          COUNT(*) FILTER (
            WHERE source_entity.bank_id = $1
              AND target_entity.bank_id = $1
          )::bigint
        FROM "#{source_prefix}".entity_links AS el
        INNER JOIN "#{source_prefix}".entities AS source_entity
          ON source_entity.id = el.source_entity_id
        INNER JOIN "#{source_prefix}".entities AS target_entity
          ON target_entity.id = el.target_entity_id
        WHERE el.bank_id = $1
        """,
        [bank_id]
      )

    if total == eligible do
      :ok
    else
      {:error,
       {:incomplete_dependent_rows,
        %{
          bank_id: bank_id,
          dependency: :entity_links,
          total_rows: total,
          eligible_rows: eligible
        }}}
    end
  end

  defp audit_file_storage_completeness(repo, source_prefix, bank_id) do
    {:ok, %{rows: [[total, eligible]]}} =
      SQL.query(
        repo,
        """
        SELECT
          COUNT(*) FILTER (WHERE doc.file_storage_key IS NOT NULL AND doc.file_storage_key != '')::bigint,
          COUNT(*) FILTER (
            WHERE doc.file_storage_key IS NOT NULL
              AND doc.file_storage_key != ''
              AND fs.storage_key IS NOT NULL
          )::bigint
        FROM "#{source_prefix}".documents AS doc
        LEFT JOIN "#{source_prefix}".file_storage AS fs
          ON fs.storage_key = doc.file_storage_key
        WHERE doc.bank_id = $1
        """,
        [bank_id]
      )

    if total == eligible do
      :ok
    else
      {:error,
       {:incomplete_dependent_rows,
        %{
          bank_id: bank_id,
          dependency: :file_storage,
          total_rows: total,
          eligible_rows: eligible
        }}}
    end
  end

  defp audit_memory_unit_embedding_rows(repo, source_prefix, target_prefix, bank_id) do
    with {:ok, source_embedding_columns} <- source_embedding_columns(repo, source_prefix),
         {:ok, target_embedding_columns} <- target_embedding_columns(repo, target_prefix),
         eligible_predicate <-
           eligible_embedding_predicate(source_embedding_columns, target_embedding_columns),
         {:ok, %{rows: [[total, eligible]]}} <-
           SQL.query(
             repo,
             """
             SELECT
               COUNT(*)::bigint,
               COUNT(*) FILTER (
                 WHERE #{eligible_predicate}
               )::bigint
             FROM "#{source_prefix}".memory_units
             WHERE bank_id = $1
             """,
             [bank_id]
           ) do
      if total == eligible do
        :ok
      else
        {:error,
         {:incompatible_embedding_rows,
          %{
            bank_id: bank_id,
            total_rows: total,
            eligible_rows: eligible,
            target_embedding_columns: target_embedding_columns
          }}}
      end
    end
  end

  defp target_embedding_columns(repo, target_prefix) do
    embedding_columns(repo, target_prefix)
  end

  defp source_embedding_columns(repo, source_prefix) do
    embedding_columns(repo, source_prefix)
  end

  defp embedding_columns(repo, prefix) do
    case SQL.query(
           repo,
           """
           SELECT column_name
           FROM information_schema.columns
           WHERE table_schema = $1
             AND table_name = 'memory_units'
             AND column_name LIKE 'embedding\_%' ESCAPE '\'
           ORDER BY column_name
           """,
           [prefix]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         rows
         |> Enum.map(fn [column_name] -> parse_embedding_column!(column_name) end)
         |> Enum.uniq()
         |> Enum.sort()}

      error ->
        error
    end
  end

  defp eligible_embedding_predicate(source_columns, target_columns) do
    source_columns
    |> Enum.filter(&(&1 in target_columns))
    |> Enum.map(fn
      384 -> "(embedded_dim = 384 AND embedding_384 IS NOT NULL)"
      1024 -> "(embedded_dim = 1024 AND embedding_1024 IS NOT NULL)"
      dim -> "(embedded_dim = #{dim} AND FALSE)"
    end)
    |> case do
      [] -> "FALSE"
      predicates -> Enum.join(predicates, " OR ")
    end
  end

  defp reassign_target_owners(repo, target_prefix) do
    {:ok, %{rows: [[current_user]]}} = SQL.query(repo, "SELECT current_user", [])

    target_prefix
    |> ownership_statements(repo, current_user)
    |> Enum.each(fn statement ->
      {:ok, _result} = SQL.query(repo, statement, [])
    end)

    :ok
  end

  defp ownership_statements(target_prefix, repo, current_user) do
    {:ok, %{rows: rows}} =
      SQL.query(
        repo,
        """
        SELECT format('ALTER SCHEMA %I OWNER TO %I', n.nspname, $2::text)
        FROM pg_namespace AS n
        WHERE n.nspname = $1
          AND pg_get_userbyid(n.nspowner) <> $2::text
        UNION ALL
        SELECT CASE c.relkind
                 WHEN 'S' THEN format('ALTER SEQUENCE %I.%I OWNER TO %I', n.nspname, c.relname, $2::text)
                 ELSE format('ALTER TABLE %I.%I OWNER TO %I', n.nspname, c.relname, $2::text)
               END
        FROM pg_class AS c
        INNER JOIN pg_namespace AS n
          ON n.oid = c.relnamespace
        WHERE n.nspname = $1
          AND c.relkind IN ('r', 'p', 'S')
          AND pg_get_userbyid(c.relowner) <> $2::text
        ORDER BY 1
        """,
        [target_prefix, current_user]
      )

    Enum.map(rows, &hd/1)
  end

  defp copy_banks(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".banks (
          id, name, mission, background, disposition, auto_consolidate, inserted_at, updated_at
        )
        SELECT
          id, name, mission, background, disposition, auto_consolidate, inserted_at, updated_at
        FROM "#{source_prefix}".banks
        WHERE id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_directives(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".directives (
          id,
          bank_id,
          name,
          content,
          priority,
          is_active,
          tags,
          metadata,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          bank_id,
          name,
          content,
          priority,
          is_active,
          tags,
          metadata,
          inserted_at,
          updated_at
        FROM "#{source_prefix}".directives
        WHERE bank_id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_webhooks(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".webhooks (
          id,
          bank_id,
          url,
          secret,
          event_types,
          enabled,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          bank_id,
          url,
          secret,
          event_types,
          enabled,
          inserted_at,
          updated_at
        FROM "#{source_prefix}".webhooks
        WHERE bank_id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_file_storage(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".file_storage (
          storage_key,
          data
        )
        SELECT DISTINCT
          fs.storage_key,
          fs.data
        FROM "#{source_prefix}".file_storage AS fs
        INNER JOIN "#{source_prefix}".documents AS doc
          ON doc.file_storage_key = fs.storage_key
        WHERE doc.bank_id = $1
          AND doc.file_storage_key IS NOT NULL
          AND doc.file_storage_key != ''
        ON CONFLICT (storage_key) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_documents(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".documents (
          id,
          bank_id,
          external_id,
          title,
          original_text,
          content_hash,
          file_storage_key,
          file_original_name,
          file_content_type,
          tags,
          metadata,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          bank_id,
          external_id,
          title,
          original_text,
          content_hash,
          file_storage_key,
          file_original_name,
          file_content_type,
          tags,
          metadata,
          inserted_at,
          updated_at
        FROM "#{source_prefix}".documents
        WHERE bank_id = $1
        ON CONFLICT (bank_id, external_id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_memory_units(repo, source_prefix, target_prefix, bank_id) do
    {:ok, source_columns} = source_embedding_columns(repo, source_prefix)
    {:ok, target_columns} = target_embedding_columns(repo, target_prefix)

    insert_embedding_columns =
      target_columns
      |> Enum.map(&"embedding_#{&1}")
      |> Enum.join(",\n          ")

    select_embedding_columns =
      target_columns
      |> Enum.map(fn dim ->
        if dim in source_columns do
          "embedding_#{dim}"
        else
          "NULL::vector AS embedding_#{dim}"
        end
      end)
      |> Enum.join(",\n          ")

    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".memory_units (
          id,
          bank_id,
          fact_type,
          content,
          context,
          #{insert_embedding_columns},
          embedded_by,
          embedded_dim,
          tags,
          proof_count,
          source_memory_ids,
          metadata,
          occurred_at,
          occurred_start,
          occurred_end,
          mentioned_at,
          observation_scopes,
          text_signals,
          consolidated_at,
          consolidation_failed_at,
          document_ref,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          bank_id,
          fact_type,
          content,
          context,
          #{select_embedding_columns},
          embedded_by,
          embedded_dim,
          tags,
          proof_count,
          source_memory_ids,
          metadata,
          occurred_at,
          occurred_start,
          occurred_end,
          mentioned_at,
          observation_scopes,
          text_signals,
          consolidated_at,
          consolidation_failed_at,
          document_ref,
          inserted_at,
          updated_at
        FROM "#{source_prefix}".memory_units
        WHERE bank_id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_entities(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".entities (
          id,
          bank_id,
          canonical_name,
          normalized_name,
          mention_count,
          first_seen,
          last_seen,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          bank_id,
          canonical_name,
          normalized_name,
          mention_count,
          first_seen,
          last_seen,
          inserted_at,
          updated_at
        FROM "#{source_prefix}".entities
        WHERE bank_id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_memory_unit_entities(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".memory_unit_entities (
          memory_unit_id,
          entity_id,
          inserted_at
        )
        SELECT
          mue.memory_unit_id,
          mue.entity_id,
          mue.inserted_at
        FROM "#{source_prefix}".memory_unit_entities AS mue
        INNER JOIN "#{source_prefix}".memory_units AS mu
          ON mu.id = mue.memory_unit_id
        INNER JOIN "#{source_prefix}".entities AS e
          ON e.id = mue.entity_id
        WHERE mu.bank_id = $1
          AND e.bank_id = $1
        ON CONFLICT (memory_unit_id, entity_id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp copy_entity_links(repo, source_prefix, target_prefix, bank_id) do
    {:ok, %{num_rows: count}} =
      SQL.query(
        repo,
        """
        INSERT INTO "#{target_prefix}".entity_links (
          id,
          bank_id,
          source_entity_id,
          target_entity_id,
          link_type,
          weight,
          inserted_at,
          updated_at
        )
        SELECT
          id,
          bank_id,
          source_entity_id,
          target_entity_id,
          link_type,
          weight,
          inserted_at,
          updated_at
        FROM "#{source_prefix}".entity_links
        WHERE bank_id = $1
        ON CONFLICT (id) DO NOTHING
        """,
        [bank_id]
      )

    count
  end

  defp parse_embedding_column!(<<"embedding_", dim::binary>>) do
    String.to_integer(dim)
  end

  defp validate_prefix(prefix) do
    if Regex.match?(@schema_pattern, prefix) do
      :ok
    else
      {:error, :invalid_prefix}
    end
  end
end
