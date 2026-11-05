defmodule Foresight.Migrations.Manifest do
  @moduledoc """
  Classifies every migration shipped with Foresight.

  The manifest is intentionally exhaustive. Consumer installation uses only the
  `:control` entries, while tenant provisioning uses only the `:tenant` entries.
  Historical `:public_data` repairs remain available to standalone deployments
  that migrate Foresight's own public schema, but are not replayed into newly
  provisioned consumer tenant schemas. Adding a packaged migration without
  classifying it makes both public operations fail closed.
  """

  @entries %{
    "20260601162000_create_banks_and_memory_units.exs" => :tenant,
    "20260601170000_create_entity_graph_tables.exs" => :tenant,
    "20260601173000_create_documents_and_attach_memory_units.exs" => :tenant,
    "20260602113000_reconcile_story_2_1_head_schema.exs" => :tenant,
    "20260602143000_create_directives.exs" => :tenant,
    "20260602152000_add_auto_consolidate_to_banks.exs" => :tenant,
    "20260624080500_add_config_overrides_to_banks.exs" => :tenant,
    "20260624092500_add_oban_jobs.exs" => :control,
    "20260624093000_add_webhook_delivery_runtime.exs" => :tenant,
    "20260625162000_add_tenant_lifecycle_ledger.exs" => :control,
    "20260625170000_add_tenant_keys_registry.exs" => :control,
    "20260626193000_add_embedding_1024_to_memory_units.exs" => :tenant,
    "20260710120000_add_prefix_to_tenant_keys.exs" => :control,
    "20260710193000_create_memory_links.exs" => :tenant,
    "20260711120000_add_embedding_1536_to_memory_units.exs" => :tenant,
    "20260711120100_pin_bank_embedding_profile.exs" => :tenant,
    "20260711130000_add_source_location_to_memory_units.exs" => :tenant,
    "20260715120000_add_pg_trgm_entity_index.exs" => :tenant,
    "20260715130000_create_entity_embeddings.exs" => :tenant,
    "20260716120000_add_entity_type.exs" => :tenant,
    "20260720120000_add_supersession_edges.exs" => :tenant,
    "20260720130000_create_labeled_pairs.exs" => :tenant,
    "20260723120000_scope_labeled_pairs_unique_index_to_bank.exs" => :tenant,
    "20260813020000_reclassify_agent_graded_labeled_pairs.exs" => :public_data,
    "20261012120000_add_embedding_3072_halfvec_to_memory_units.exs" => :tenant,
    "20261012121000_create_mental_model_embeddings.exs" => :tenant
  }

  @typedoc "A packaged migration's installation target."
  @type classification :: :control | :tenant | :public_data

  @doc "Returns the complete filename-to-classification manifest."
  @spec entries() :: %{String.t() => classification()}
  def entries, do: @entries

  @doc "Returns sorted packaged migration filenames for one classification."
  @spec files(classification()) :: [String.t()]
  def files(classification) when classification in [:control, :tenant, :public_data] do
    @entries
    |> Enum.filter(fn {_filename, value} -> value == classification end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  @doc """
  Verifies that `path` contains exactly the migrations in the manifest.

  Unknown, missing, duplicate-version, and malformed migration files are
  rejected. This prevents a newly packaged migration from silently landing in
  the wrong schema.
  """
  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(path) when is_binary(path) do
    actual =
      path
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    expected = @entries |> Map.keys() |> Enum.sort()

    with :ok <- validate_file_set(actual, expected),
         :ok <- validate_versions(actual) do
      :ok
    end
  end

  defp validate_file_set(actual, expected) when actual == expected, do: :ok

  defp validate_file_set(actual, expected) do
    {:error,
     {:migration_manifest_mismatch,
      %{unclassified: actual -- expected, missing: expected -- actual}}}
  end

  defp validate_versions(files) do
    with {:ok, versions} <- parse_versions(files) do
      duplicates =
        versions
        |> Enum.frequencies()
        |> Enum.filter(fn {_version, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      if duplicates == [] do
        :ok
      else
        {:error, {:migration_version_collision, duplicates}}
      end
    end
  end

  defp parse_versions(files) do
    Enum.reduce_while(files, {:ok, []}, fn filename, {:ok, versions} ->
      case Integer.parse(filename) do
        {version, "_" <> _name} ->
          {:cont, {:ok, [version | versions]}}

        _ ->
          {:halt, {:error, {:invalid_migration_filename, filename}}}
      end
    end)
  end
end
