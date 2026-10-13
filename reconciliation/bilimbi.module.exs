[
  id: "finance/reconciliation",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_reconciliation,
  namespace: Bilimbi.Finance.Reconciliation,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/attachments",
    "finance/ledger"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_014_090_000 => :bilimbi_only,
    20_261_017_090_100 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Reconciliation.Contributions,
  dev_seed: nil
]
