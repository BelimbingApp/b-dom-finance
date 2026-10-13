[
  id: "finance/attachments",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_attachments,
  namespace: Bilimbi.Finance.Attachments,
  dependencies: [
    "base/artifacts",
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/queue",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/ledger"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{20_261_017_090_000 => :bilimbi_only},
  web: "priv/web_routes.exs",
  # Compatibility verification runs before pending Bilimbi-only migrations.
  # Registering these fresh tables would make adoption expect them already;
  # test/schema_contract_test.exs verifies the contract instead.
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Attachments.Contributions,
  dev_seed: nil
]
