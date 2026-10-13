[
  id: "finance/payables",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_payables,
  namespace: Bilimbi.Finance.Payables,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/ledger"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_012_213_700 => :bilimbi_only,
    20_261_014_100_000 => :bilimbi_only,
    20_261_016_100_100 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Payables.Contributions,
  dev_seed: nil
]
