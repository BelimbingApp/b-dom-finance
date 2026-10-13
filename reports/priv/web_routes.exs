[
  %{
    path: "/finance/reports/auditor-packs/:artifact_id",
    controller: Bilimbi.Finance.Reports.Web.AuditorPackController,
    action: :show,
    session: :auth,
    capability: "finance.reports.export"
  },
  %{
    path: "/finance/reports",
    live: Bilimbi.Finance.Reports.Web.ReportsLive,
    session: :auth,
    capability: "finance.ledger.view"
  },
  %{
    path: "/finance/reports/accounts/:account_id",
    live: Bilimbi.Finance.Reports.Web.AccountActivityLive,
    session: :auth,
    capability: "finance.ledger.view"
  }
]
