[
  %{
    path: "/finance/reconciliation",
    live: Bilimbi.Finance.Reconciliation.Web.BankAccountsLive,
    session: :auth,
    capability: "finance.reconciliation.view"
  },
  %{
    path: "/finance/reconciliation/accounts/:id",
    live: Bilimbi.Finance.Reconciliation.Web.ImportLive,
    session: :auth,
    capability: "finance.reconciliation.view"
  },
  %{
    path: "/finance/reconciliation/accounts/:id/matching",
    live: Bilimbi.Finance.Reconciliation.Web.MatchingLive,
    session: :auth,
    capability: "finance.reconciliation.view"
  },
  %{
    path: "/finance/reconciliation/reconciliations/:id",
    live: Bilimbi.Finance.Reconciliation.Web.ReconciliationLive,
    session: :auth,
    capability: "finance.reconciliation.view"
  }
]
