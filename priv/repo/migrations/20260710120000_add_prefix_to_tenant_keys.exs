defmodule Foresight.Repo.Migrations.AddPrefixToTenantKeys do
  use Ecto.Migration

  # The tenant-key registry now carries the tenant's schema prefix alongside the
  # role, so request resolution derives BOTH the role and the schema server-side in
  # a single lookup (previously the prefix was trusted from a client header). The
  # column is nullable for backward-compatibility: legacy rows fall back to the
  # TenantLifecycle ledger for their prefix.
  def change do
    alter table(:tenant_keys) do
      add(:prefix, :string)
    end
  end
end
