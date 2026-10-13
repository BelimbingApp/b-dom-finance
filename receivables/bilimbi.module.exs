[
  id: "finance/receivables",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_receivables,
  namespace: Bilimbi.Finance.Receivables,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "core/company",
    "finance/ledger"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_012_214_517 => :bilimbi_only,
    20_261_015_150_100 => :bilimbi_only
  },
  web: nil,
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Receivables.Contributions,
  dev_seed: nil
]
