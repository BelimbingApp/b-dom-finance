Code.ensure_loaded!(Bilimbi.Base.Database.DataCase)
Code.ensure_loaded!(Bilimbi.Base.Tenancy.TestFixtures)
Code.ensure_loaded!(Bilimbi.Base.Authz.TestFixtures)
Code.ensure_loaded!(Bilimbi.Core.Geonames.TestFixtures)
Code.ensure_loaded!(Bilimbi.Core.Company.TestFixtures)
Code.ensure_loaded!(Bilimbi.Finance.Ledger.TestFixtures)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
