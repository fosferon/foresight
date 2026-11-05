defmodule Foresight.Migration.BankMigrator do
  @moduledoc false

  alias Foresight.Migration.EmbeddingAudit
  alias Foresight.Migration.ParityProbe
  alias Foresight.Migration.SourceDrop
  alias Foresight.Migration.VerbatimCopy
  alias Foresight.Tenancy.SchemaProvisioner

  @default_repo Foresight.Repo
  @excluded_surfaces [:audit_log]

  @spec migrate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             bank_id: String.t(),
             source_prefix: String.t(),
             target_prefix: String.t(),
             migration_policy: map(),
             target_provisioned: map(),
             source_audit: map(),
             copy_result: map(),
             parity_probe: map(),
             source_cleanup: map()
           }}
          | {:error, term()}

  @spec probe(String.t(), String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             bank_id: String.t(),
             source_prefix: String.t(),
             target_prefix: String.t(),
             migration_policy: map(),
             target_provisioned: map(),
             source_audit: map(),
             parity_probe: map()
           }}
          | {:error, term()}
  def migrate(source_prefix, target_prefix, bank_id, opts \\ [])

  def migrate(source_prefix, target_prefix, bank_id, opts)
      when is_binary(source_prefix) and is_binary(target_prefix) and is_binary(bank_id) do
    repo = Keyword.get(opts, :repo, @default_repo)

    with {:ok, target_provisioned} <-
           SchemaProvisioner.provision(
             target_prefix,
             [repo: repo] ++ Keyword.take(opts, [:rls_enabled])
           ),
         {:ok, source_audit} <-
           wrap_source_audit(
             EmbeddingAudit.audit_schema(source_prefix, repo: repo, bank_id: bank_id),
             bank_id,
             source_prefix,
             target_prefix,
             target_provisioned
           ),
         {:ok, copy_result} <-
           wrap_copy_result(
             VerbatimCopy.copy_bank(source_prefix, target_prefix, bank_id, repo: repo),
             bank_id,
             source_prefix,
             target_prefix,
             target_provisioned,
             source_audit
           ),
         {:ok, parity_probe} <-
           ParityProbe.probe_bank(source_prefix, target_prefix, bank_id, repo: repo),
         :ok <-
           wrap_probe_result(
             require_clean_probe(parity_probe),
             bank_id,
             source_prefix,
             target_prefix,
             target_provisioned,
             source_audit,
             copy_result,
             parity_probe
           ),
         {:ok, source_cleanup} <-
           wrap_source_cleanup(
             SourceDrop.drop_bank(source_prefix, bank_id, repo: repo),
             bank_id,
             source_prefix,
             target_prefix,
             target_provisioned,
             source_audit,
             copy_result,
             parity_probe
           ) do
      {:ok,
       %{
         bank_id: bank_id,
         source_prefix: source_prefix,
         target_prefix: target_prefix,
         migration_policy: migration_policy(),
         target_provisioned: target_provisioned,
         source_audit: source_audit,
         copy_result: copy_result,
         parity_probe: parity_probe,
         source_cleanup: source_cleanup
       }}
    end
  end

  def migrate(_source_prefix, _target_prefix, _bank_id, _opts), do: {:error, :invalid_prefix}

  def probe(source_prefix, target_prefix, bank_id, opts \\ [])

  def probe(source_prefix, target_prefix, bank_id, opts)
      when is_binary(source_prefix) and is_binary(target_prefix) and is_binary(bank_id) do
    repo = Keyword.get(opts, :repo, @default_repo)

    with {:ok, target_provisioned} <-
           SchemaProvisioner.provision(
             target_prefix,
             [repo: repo] ++ Keyword.take(opts, [:rls_enabled])
           ),
         {:ok, source_audit} <-
           wrap_source_audit(
             EmbeddingAudit.audit_schema(source_prefix, repo: repo, bank_id: bank_id),
             bank_id,
             source_prefix,
             target_prefix,
             target_provisioned
           ),
         {:ok, parity_probe} <-
           ParityProbe.probe_bank(source_prefix, target_prefix, bank_id, repo: repo),
         :ok <-
           wrap_probe_result(
             require_clean_probe(parity_probe),
             bank_id,
             source_prefix,
             target_prefix,
             target_provisioned,
             source_audit,
             nil,
             parity_probe
           ) do
      {:ok,
       %{
         bank_id: bank_id,
         source_prefix: source_prefix,
         target_prefix: target_prefix,
         migration_policy: migration_policy(),
         target_provisioned: target_provisioned,
         source_audit: source_audit,
         parity_probe: parity_probe
       }}
    end
  end

  def probe(_source_prefix, _target_prefix, _bank_id, _opts), do: {:error, :invalid_prefix}

  defp require_clean_probe(%{clean?: true}), do: :ok
  defp require_clean_probe(probe), do: {:error, {:parity_probe_failed, probe}}

  defp wrap_source_audit(
         {:ok, %{compatible?: false} = source_audit},
         bank_id,
         source_prefix,
         target_prefix,
         target_provisioned
       ) do
    {:error,
     {:migration_diagnostics,
      %{
        stage: :audit,
        failure_kind: :incompatible_source_audit,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: migration_policy(),
        target_provisioned: target_provisioned,
        source_audit: source_audit,
        detail: source_audit
      }}}
  end

  defp wrap_source_audit(
         {:ok, source_audit},
         _bank_id,
         _source_prefix,
         _target_prefix,
         _target_provisioned
       ),
       do: {:ok, source_audit}

  defp wrap_source_audit(result, _bank_id, _source_prefix, _target_prefix, _target_provisioned),
    do: result

  defp wrap_copy_result(
         {:error, {:incomplete_dependent_rows, detail}},
         bank_id,
         source_prefix,
         target_prefix,
         target_provisioned,
         source_audit
       ) do
    {:error,
     {:migration_diagnostics,
      %{
        stage: :copy,
        failure_kind: :incomplete_dependent_rows,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: migration_policy(),
        target_provisioned: target_provisioned,
        source_audit: source_audit,
        detail: detail
      }}}
  end

  defp wrap_copy_result(
         {:error, {:incompatible_embedding_rows, detail}},
         bank_id,
         source_prefix,
         target_prefix,
         target_provisioned,
         source_audit
       ) do
    {:error,
     {:migration_diagnostics,
      %{
        stage: :copy,
        failure_kind: :incompatible_embedding_rows,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: migration_policy(),
        target_provisioned: target_provisioned,
        source_audit: source_audit,
        detail: detail
      }}}
  end

  defp wrap_copy_result(
         result,
         _bank_id,
         _source_prefix,
         _target_prefix,
         _target_provisioned,
         _source_audit
       ),
       do: result

  defp wrap_probe_result(
         {:error, {:parity_probe_failed, probe}},
         bank_id,
         source_prefix,
         target_prefix,
         target_provisioned,
         source_audit,
         copy_result,
         _parity_probe
       ) do
    diagnostics =
      %{
        stage: :probe,
        failure_kind: :parity_probe_failed,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: migration_policy(),
        target_provisioned: target_provisioned,
        source_audit: source_audit,
        detail: probe
      }
      |> maybe_put_copy_result(copy_result)

    {:error, {:migration_diagnostics, diagnostics}}
  end

  defp wrap_probe_result(
         result,
         _bank_id,
         _source_prefix,
         _target_prefix,
         _target_provisioned,
         _source_audit,
         _copy_result,
         _parity_probe
       ),
       do: result

  defp wrap_source_cleanup(
         {:error, reason},
         bank_id,
         source_prefix,
         target_prefix,
         target_provisioned,
         source_audit,
         copy_result,
         parity_probe
       ) do
    {:error,
     {:migration_diagnostics,
      %{
        stage: :drop_source,
        failure_kind: :source_cleanup_failed,
        bank_id: bank_id,
        source_prefix: source_prefix,
        target_prefix: target_prefix,
        migration_policy: migration_policy(),
        target_provisioned: target_provisioned,
        source_audit: source_audit,
        copy_result: copy_result,
        detail: %{
          parity_probe: parity_probe,
          source_cleanup_error: inspect(reason)
        }
      }}}
  end

  defp wrap_source_cleanup(
         {:ok, source_cleanup},
         _bank_id,
         _source_prefix,
         _target_prefix,
         _target_provisioned,
         _source_audit,
         _copy_result,
         _parity_probe
       ),
       do: {:ok, source_cleanup}

  defp migration_policy do
    %{excluded_surfaces: @excluded_surfaces}
  end

  defp maybe_put_copy_result(diagnostics, nil), do: diagnostics

  defp maybe_put_copy_result(diagnostics, copy_result),
    do: Map.put(diagnostics, :copy_result, copy_result)
end
