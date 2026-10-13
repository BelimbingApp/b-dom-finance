[
  %{
    path: "/finance/fixed-assets/register",
    live: Bilimbi.Finance.FixedAssets.Web.RegisterLive,
    session: :auth,
    capability: "finance.fixed-assets.view"
  },
  %{
    path: "/finance/fixed-assets/categories",
    live: Bilimbi.Finance.FixedAssets.Web.CategoriesLive,
    session: :auth,
    capability: "finance.fixed-assets.view"
  },
  %{
    path: "/finance/fixed-assets/runs",
    live: Bilimbi.Finance.FixedAssets.Web.RunsLive,
    session: :auth,
    capability: "finance.fixed-assets.view"
  },
  %{
    path: "/finance/fixed-assets/register/:id",
    live: Bilimbi.Finance.FixedAssets.Web.AssetLive,
    session: :auth,
    capability: "finance.fixed-assets.view"
  }
]
