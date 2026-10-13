[
  %{
    path: "/finance/payroll",
    live: Bilimbi.Finance.Payroll.Web.PostingsLive,
    session: :auth,
    capability: "finance.payroll.view"
  },
  %{
    path: "/finance/payroll/setup",
    live: Bilimbi.Finance.Payroll.Web.SetupLive,
    session: :auth,
    capability: "finance.payroll.view"
  }
]
