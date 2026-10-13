[
  id: "finance/fixed_assets",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_fixed_assets,
  namespace: Bilimbi.Finance.FixedAssets,
  dependencies: [
    "base/authz",
    "base/database",
    "base/module_registry",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/ledger",
    "finance/payables"
  ],
  migrations: "priv/repo/migrations",
  migration_dispositions: %{
    20_261_015_110_000 => :bilimbi_only,
    20_261_015_150_700 => :bilimbi_only
  },
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.FixedAssets.Contributions,
  dev_seed: nil
]
