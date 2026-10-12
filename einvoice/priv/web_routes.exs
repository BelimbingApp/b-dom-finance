[
  %{
    path: "/finance/einvoice/documents",
    live: Bilimbi.Finance.Einvoice.Web.DocumentsLive,
    session: :auth,
    capability: "finance.einvoice.view"
  },
  %{
    path: "/finance/einvoice/documents/:id",
    live: Bilimbi.Finance.Einvoice.Web.DocumentLive,
    session: :auth,
    capability: "finance.einvoice.view"
  },
  %{
    path: "/finance/einvoice/documents/:id/pdf/:artifact_id",
    controller: Bilimbi.Finance.Einvoice.Web.PdfController,
    action: :show,
    session: :auth,
    capability: "finance.einvoice.view"
  },
  %{
    path: "/finance/einvoice/reconciliation",
    live: Bilimbi.Finance.Einvoice.Web.ReconciliationLive,
    session: :auth,
    capability: "finance.einvoice.view"
  },
  %{
    path: "/finance/einvoice/setup",
    live: Bilimbi.Finance.Einvoice.Web.SetupLive,
    session: :auth,
    capability: "finance.einvoice.settings.manage"
  }
]
