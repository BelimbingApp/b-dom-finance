[
  id: "finance/reports",
  kind: :module,
  layer: :domain,
  required: false,
  otp_app: :bilimbi_finance_reports,
  namespace: Bilimbi.Finance.Reports,
  dependencies: [
    "base/module_registry",
    "base/settings",
    "base/tenancy",
    "base/ui",
    "core/company",
    "finance/ledger"
  ],
  migrations: nil,
  web: "priv/web_routes.exs",
  schema_contract: nil,
  contribution_provider: Bilimbi.Finance.Reports.Contributions,
  dev_seed: nil
]
