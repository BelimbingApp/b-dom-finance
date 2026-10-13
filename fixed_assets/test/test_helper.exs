Code.ensure_loaded!(Bilimbi.Base.Database.DataCase)
Code.ensure_loaded!(Bilimbi.Finance.Payables.TestFixtures)
Code.ensure_loaded!(Bilimbi.Finance.Ledger.TestFixtures)
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)

Code.require_file(
  "../priv/repo/migrations/20261015110000_create_finance_fixed_assets.exs",
  __DIR__
)
