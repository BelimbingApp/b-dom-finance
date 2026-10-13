[
  %{
    path: "/finance/sst",
    live: Bilimbi.Finance.Sst.Web.ReturnsLive,
    session: :auth,
    capability: "finance.sst.view"
  },
  %{
    path: "/finance/sst/setup",
    live: Bilimbi.Finance.Sst.Web.SetupLive,
    session: :auth,
    capability: "finance.sst.view"
  },
  %{
    path: "/finance/sst/returns/:id",
    live: Bilimbi.Finance.Sst.Web.ReturnLive,
    session: :auth,
    capability: "finance.sst.view"
  },
  %{
    path: "/finance/sst/returns/:id/export.csv",
    controller: Bilimbi.Finance.Sst.Web.ExportController,
    action: :csv,
    session: :auth,
    capability: "finance.sst.view"
  },
  %{
    path: "/finance/sst/returns/:id/print",
    controller: Bilimbi.Finance.Sst.Web.ExportController,
    action: :print,
    session: :auth,
    capability: "finance.sst.view"
  }
]
