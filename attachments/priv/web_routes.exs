[
  %{
    path: "/finance/attachments",
    live: Bilimbi.Finance.Attachments.Web.IndexLive,
    session: :auth,
    capability: "finance.attachments.view"
  },
  %{
    path: "/finance/attachments/:id/download",
    controller: Bilimbi.Finance.Attachments.Web.DownloadController,
    action: :show,
    session: :auth,
    capability: "finance.attachments.view"
  }
]
