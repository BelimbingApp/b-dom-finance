[
  id: "finance/sst",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_sst,
  namespace: Bilimbi.Finance.Sst,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/ledger",
    "finance/payables",
    "finance/receivables"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_015_090_000 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Sst.Contributions,
  dev_seed: nil
]
