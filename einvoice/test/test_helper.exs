Code.ensure_loaded!(Bilimbi.Base.Database.DataCase)
Code.ensure_loaded!(Bilimbi.Base.Tenancy.TestFixtures)
Code.ensure_loaded!(Bilimbi.Base.Authz.TestFixtures)
Code.ensure_loaded!(Bilimbi.Base.Settings.TestFixtures)
Code.ensure_loaded!(Bilimbi.Base.Audit.TestFixtures)
Code.ensure_loaded!(Bilimbi.Base.Integration.TestFixtures)
Code.ensure_loaded!(Bilimbi.Core.Geonames.TestFixtures)
Code.ensure_loaded!(Bilimbi.Core.Company.TestFixtures)

# Every authority call in this suite answers from a Req.Test stub; nothing
# leaves the machine.
Application.put_env(:bilimbi_finance_einvoice, :req_options,
  plug: {Req.Test, Bilimbi.Finance.Einvoice.MyInvois.Client}
)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Bilimbi.Base.Repo, :manual)
