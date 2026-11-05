defmodule Foresight.Migration.EmbeddingAudit do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Foresight.Config

  @default_repo Foresight.Repo

  @spec audit_schema(String.t(), keyword()) ::
          {:ok,
           %{
             prefix: String.t(),
             configured_embedding_model: String.t(),
             pinned_default_model: String.t(),
             pinned_default_dimension: pos_integer(),
             pinned_default_match?: boolean(),
             stored_embedded_by: [String.t()],
             row_count: non_neg_integer(),
             embedded_dims: [integer()],
             embedding_columns: [integer()],
             table_audits: [map()],
             compatible?: boolean()
           }}
          | {:error, term()}
  def audit_schema(prefix, opts \\ [])

  def audit_schema(prefix, opts) when is_binary(prefix) do
    repo = Keyword.get(opts, :repo, @default_repo)
    bank_id = Keyword.get(opts, :bank_id)

    pinned_default_dimension =
      Keyword.get(opts, :pinned_default_dimension, pinned_default_dimension())

    pinned_default_model = Keyword.get(opts, :pinned_default_model, pinned_default_model())

    with {:ok, embedding_columns} <- embedding_columns(repo, prefix),
         {:ok, table_audits} <-
           table_audits(
             repo,
             prefix,
             bank_id,
             embedding_columns,
             pinned_default_dimension
           ) do
      stored_embedded_by =
        table_audits
        |> Enum.flat_map(& &1.embedded_by)
        |> Enum.uniq()
        |> Enum.sort()

      configured_embedding_model =
        Keyword.get_lazy(opts, :configured_embedding_model, fn ->
          infer_configured_embedding_model(stored_embedded_by, pinned_default_model)
        end)

      embedded_dims =
        table_audits
        |> Enum.flat_map(& &1.embedded_dims)
        |> Enum.uniq()
        |> Enum.sort()

      row_count =
        Enum.reduce(table_audits, 0, fn table_audit, acc ->
          acc + table_audit.row_count
        end)

      pinned_default_match? =
        configured_embedding_model == pinned_default_model and
          Enum.all?(table_audits, & &1.pinned_default_dimension_match?)

      {:ok,
       %{
         prefix: prefix,
         configured_embedding_model: configured_embedding_model,
         pinned_default_model: pinned_default_model,
         pinned_default_dimension: pinned_default_dimension,
         pinned_default_match?: pinned_default_match?,
         stored_embedded_by: stored_embedded_by,
         row_count: row_count,
         embedded_dims: embedded_dims,
         embedding_columns: embedding_columns,
         table_audits: table_audits,
         compatible?: Enum.all?(table_audits, & &1.compatible?) and pinned_default_match?
       }}
    end
  end

  def audit_schema(_prefix, _opts), do: {:error, :invalid_prefix}

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
         |> Enum.map(&hd/1)
         |> Enum.map(&parse_embedding_column!/1)
         |> Enum.uniq()
         |> Enum.sort()}

      error ->
        error
    end
  end

  defp table_audits(repo, prefix, bank_id, embedding_columns, pinned_default_dimension) do
    {sql, params} = embedded_dims_query(prefix, bank_id)

    case SQL.query(
           repo,
           sql,
           params
         ) do
      {:ok, %{rows: rows}} ->
        table_audits =
          rows
          |> Enum.map(fn [bank_id, embedded_dim, embedded_by, count] ->
            %{
              bank_id: bank_id,
              table: "memory_units",
              row_count: count,
              embedded_dims: [embedded_dim],
              embedded_by: List.wrap(embedded_by) |> Enum.reject(&is_nil/1) |> Enum.sort(),
              vector_dimensions: embedding_columns,
              pinned_default_dimension_match?: embedded_dim == pinned_default_dimension,
              compatible?: embedded_dim in embedding_columns
            }
          end)
          |> merge_table_audits()

        {:ok, table_audits}

      error ->
        error
    end
  end

  defp embedded_dims_query(prefix, nil) do
    {
      """
      SELECT bank_id, embedded_dim, array_agg(DISTINCT embedded_by ORDER BY embedded_by), count(*)
      FROM "#{prefix}".memory_units
      GROUP BY bank_id, embedded_dim
      ORDER BY bank_id, embedded_dim
      """,
      []
    }
  end

  defp embedded_dims_query(prefix, bank_id) do
    {
      """
      SELECT bank_id, embedded_dim, array_agg(DISTINCT embedded_by ORDER BY embedded_by), count(*)
      FROM "#{prefix}".memory_units
      WHERE bank_id = $1
      GROUP BY bank_id, embedded_dim
      ORDER BY bank_id, embedded_dim
      """,
      [bank_id]
    }
  end

  defp merge_table_audits(rows) do
    rows
    |> Enum.group_by(&{&1.bank_id, &1.table})
    |> Enum.map(fn {{bank_id, table}, grouped_rows} ->
      row_count = Enum.reduce(grouped_rows, 0, fn row, acc -> acc + row.row_count end)

      embedded_dims =
        grouped_rows
        |> Enum.flat_map(& &1.embedded_dims)
        |> Enum.uniq()
        |> Enum.sort()

      embedded_by =
        grouped_rows
        |> Enum.flat_map(& &1.embedded_by)
        |> Enum.uniq()
        |> Enum.sort()

      vector_dimensions =
        grouped_rows
        |> Enum.flat_map(& &1.vector_dimensions)
        |> Enum.uniq()
        |> Enum.sort()

      %{
        bank_id: bank_id,
        table: table,
        row_count: row_count,
        embedded_dims: embedded_dims,
        embedded_by: embedded_by,
        vector_dimensions: vector_dimensions,
        pinned_default_dimension_match?:
          Enum.all?(grouped_rows, & &1.pinned_default_dimension_match?),
        compatible?: Enum.all?(grouped_rows, & &1.compatible?)
      }
    end)
    |> Enum.sort_by(&{&1.bank_id || "", &1.table})
  end

  defp parse_embedding_column!(<<"embedding_", dim::binary>>) do
    String.to_integer(dim)
  end

  defp infer_configured_embedding_model([], pinned_default_model), do: pinned_default_model

  defp infer_configured_embedding_model([single_model], pinned_default_model) do
    if model_identifier?(single_model), do: single_model, else: pinned_default_model
  end

  defp infer_configured_embedding_model(multiple_models, pinned_default_model) do
    model_ids = Enum.filter(multiple_models, &model_identifier?/1)

    case Enum.uniq(model_ids) do
      [] -> pinned_default_model
      [single_model] -> single_model
      _multiple_models -> "mixed"
    end
  end

  defp model_identifier?(value) when is_binary(value), do: String.contains?(value, "/")
  defp model_identifier?(_value), do: false

  defp pinned_default_model do
    Config.resolve().ml.model_id
  end

  defp pinned_default_dimension do
    384
  end
end
