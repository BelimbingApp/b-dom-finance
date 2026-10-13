defmodule Bilimbi.Finance.Reports.IssuedCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  alias Bilimbi.Base.{Repo, ModuleRegistry.ContributionRegistry}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Bilimbi.Finance.Reports
      alias Bilimbi.Finance.Reports.TestFixtures
      alias Bilimbi.Finance.Ledger
      alias Bilimbi.Base.Repo
      alias Ecto.Adapters.SQL
    end
  end

  setup do
    # These APIs require real transaction boundaries. A non-sandboxed owned
    # connection keeps the owner's temporary tables while allowing commits.
    owner = Sandbox.start_owner!(Repo, sandbox: false, shared: true)
    schema = "finance_reports_authz_#{String.replace(Ecto.UUID.generate(), "-", "")}"
    SQL.query!(Repo, "CREATE SCHEMA #{schema}", [])
    SQL.query!(Repo, "SET search_path TO #{schema}", [])

    on_exit(fn ->
      Sandbox.allow(Repo, owner, self())
      SQL.query!(Repo, "DISCARD TEMP", [])
      SQL.query!(Repo, "SET search_path TO public", [])
      SQL.query!(Repo, "DROP SCHEMA #{schema} CASCADE", [])
      Sandbox.stop_owner(owner)
      ContributionRegistry.clear_for_test!()
    end)

    {:ok, context} =
      Repo.transact(fn ->
        context = Bilimbi.Finance.Reports.TestFixtures.setup_reports!()
        Bilimbi.Finance.Receivables.TestFixtures.create_receivables_tables!()
        Bilimbi.Finance.Payables.TestFixtures.create_payables_tables!()
        Bilimbi.Finance.Reconciliation.TestFixtures.create_reconciliation_tables!()
        Bilimbi.Finance.Einvoice.TestFixtures.create_einvoice_tables!()
        Bilimbi.Finance.Payroll.TestFixtures.create_payroll_tables!()
        Bilimbi.Finance.Sst.TestFixtures.create_sst_tables!()
        Bilimbi.Base.Audit.TestFixtures.create_audit_tables!()
        Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()

        migration = Bilimbi.Finance.Reports.Migrations.CreateIssuedReports

        unless Code.ensure_loaded?(migration),
          do:
            Code.require_file(
              Path.expand(
                "../../priv/repo/migrations/20261015100000_create_issued_reports.exs",
                __DIR__
              )
            )

        Enum.each(apply(migration, :statements, [[temporary: true]]), &SQL.query!(Repo, &1, []))
        {:ok, context}
      end)

    # Authz's sandbox-only tables drop at commit. Its supported persistent
    # fixture builds the same contract in this test's isolated schema.
    Bilimbi.Base.Authz.TestFixtures.create_authz_tables!(persistent: true)
    Bilimbi.Base.Authz.TestFixtures.create_field_restriction_tables!(persistent: true)
    install_snapshot!()

    capabilities = [
      "finance.ledger.view",
      "finance.ledger.accounts.manage",
      "finance.ledger.entries.post",
      "finance.reports.issue",
      "finance.reports.reports-export",
      "finance.receivables.view",
      "finance.payables.view",
      "finance.reconciliation.view",
      "finance.einvoice.view",
      "finance.payroll.view",
      "finance.sst.view"
    ]

    operator =
      Bilimbi.Finance.Ledger.TestFixtures.sign_in!(context.first_scope, 73, 91, capabilities)

    %{context | operator: operator}
  end

  defp install_snapshot! do
    entries =
      for {id, provider} <- [
            {"base/authz", Bilimbi.Base.Authz.Contributions},
            {"base/artifacts", Bilimbi.Base.Artifacts.Contributions},
            {"core/company", Bilimbi.Core.Company.Contributions},
            {"finance/ledger", Bilimbi.Finance.Ledger.Contributions},
            {"finance/reports", Bilimbi.Finance.Reports.Contributions},
            {"finance/receivables", Bilimbi.Finance.Receivables.Contributions},
            {"finance/payables", Bilimbi.Finance.Payables.Contributions},
            {"finance/reconciliation", Bilimbi.Finance.Reconciliation.Contributions},
            {"finance/einvoice", Bilimbi.Finance.Einvoice.Contributions},
            {"finance/payroll", Bilimbi.Finance.Payroll.Contributions},
            {"finance/sst", Bilimbi.Finance.Sst.Contributions}
          ] do
        payload = provider.contributions()
        %{descriptor: %{id: id, otp_app: Application.get_application(provider)}, payload: payload}
      end

    authz =
      for entry <- entries,
          Map.has_key?(entry.payload, :authz),
          do: %{entry | payload: entry.payload.authz}

    settings =
      for entry <- entries,
          Map.has_key?(entry.payload, :settings),
          do: %{entry | payload: entry.payload.settings}

    ContributionRegistry.put_consumers_for_test!(
      %{
        authz: Bilimbi.Base.Authz.ContributionValidator.validate_contributions!(authz),
        settings: Bilimbi.Base.Settings.ContributionValidator.validate_contributions!(settings)
      },
      "finance-issued-test"
    )
  end
end
