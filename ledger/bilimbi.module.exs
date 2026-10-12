[
  id: "finance/ledger",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_ledger,
  namespace: Bilimbi.Finance.Ledger,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "core/company"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_012_170_100 => :bilimbi_only,
    20_261_012_214_100 => :bilimbi_only
  },
  web: nil,
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Ledger.Contributions,
  dev_seed: nil
]
