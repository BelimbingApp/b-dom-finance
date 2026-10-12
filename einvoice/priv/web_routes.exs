[
  %{
    path: "/finance/einvoice/setup",
    live: Bilimbi.Finance.Einvoice.Web.SetupLive,
    session: :auth,
    capability: "finance.einvoice.settings.manage"
  }
]
