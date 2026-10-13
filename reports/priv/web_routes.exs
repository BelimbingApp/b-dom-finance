[
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
  },
  %{
    path: "/finance/reports/approval-exceptions",
    live: Bilimbi.Finance.Reports.Web.ApprovalExceptionsLive,
    session: :auth,
    capability: "finance.ledger.view"
  }
]
