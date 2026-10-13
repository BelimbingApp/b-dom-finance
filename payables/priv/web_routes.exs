[
  %{
    path: "/finance/payables/bills",
    live: Bilimbi.Finance.Payables.Web.BillsLive,
    session: :auth,
    capability: "finance.payables.view"
  },
  %{
    path: "/finance/payables/bills/:id",
    live: Bilimbi.Finance.Payables.Web.BillLive,
    session: :auth,
    capability: "finance.payables.view"
  }
]
