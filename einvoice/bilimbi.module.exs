[
  id: "finance/einvoice",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_einvoice,
  namespace: Bilimbi.Finance.Einvoice,
  dependencies: [
    "base/audit",
    "base/authz",
    "base/database",
    "base/integration",
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_012_200_000 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Einvoice.Contributions,
  dev_seed: nil
]
