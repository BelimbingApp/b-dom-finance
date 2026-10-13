[
  id: "finance/payroll",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_payroll,
  namespace: Bilimbi.Finance.Payroll,
  dependencies: [
    "base/authz",
    "base/database",
    "base/datetime",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/ledger"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_015_120_000 => :bilimbi_only,
    20_261_015_150_500 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Payroll.Contributions,
  dev_seed: nil
]
