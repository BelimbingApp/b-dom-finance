defmodule Bilimbi.Finance.Receivables.TestFixtures do
  @moduledoc """
  Receivables and ledger tables, authorization, two tenants' companies, and
  an open book with a small chart for module tests.

  The receivables tables are temporary copies built from the migration's own
  statements (`CreateReceivables.statements(temporary: true)`), constraints
  and triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. `test/schema_contract_test.exs` checks the real
  migration itself. The ledger's tables come from its own fixtures.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Receivables
  alias Ecto.Adapters.SQL

  @migration Path.expand(
               "../../priv/repo/migrations/20261012214517_create_finance_receivables.exs",
               __DIR__
             )

  @ledger ["finance.ledger.view", "finance.ledger.accounts.manage", "finance.ledger.entries.post"]

  @doc "The migration module, loaded from its file once."
  def migration do
    module = Bilimbi.Finance.Receivables.Migrations.CreateReceivables
    unless Code.ensure_loaded?(module), do: Code.require_file(@migration)
    module
  end

  @doc "Every ledger capability, which receivables' own calls into the ledger need."
  def ledger_capabilities, do: @ledger

  @doc "Every receivables capability."
  def receivables_capabilities do
    [
      Receivables.view_capability(),
      Receivables.manage_setup_capability(),
      Receivables.manage_customers_capability(),
      Receivables.manage_documents_capability(),
      Receivables.issue_documents_capability(),
      Receivables.post_payments_capability()
    ]
  end

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  tables, and an Authz snapshot. Signs in user 91 at company 73 with every
  ledger and receivables capability, opens company 73's book in `XTS` with
  two minor units, and creates its chart: cash (1000), receivable (1100),
  tax payable (2100), equity (3000), and two income accounts (4000, 4100).
  Returns the scopes and the accounts.
  """
  def setup_receivables! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    LedgerFixtures.create_ledger_tables!()
    create_receivables_tables!()
    install_authz!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    operator = sign_in!(first, 73, 91, @ledger ++ receivables_capabilities())

    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    accounts =
      Map.new(
        [
          cash: {"1000", "asset"},
          receivable: {"1100", "asset"},
          tax: {"2100", "liability"},
          equity: {"3000", "equity"},
          income: {"4000", "income"},
          other_income: {"4100", "income"}
        ],
        fn {key, {code, type}} ->
          {:ok, account} =
            Ledger.create_account(operator, 73, %{
              code: code,
              name: "Account #{code}",
              account_type: type
            })

          {key, account}
        end
      )

    %{first_scope: first, second_scope: second, operator: operator, accounts: accounts}
  end

  @doc """
  Configures company 73 with the fixture accounts, an invoice, credit note,
  and payment series, a 10% and a 6% tax code, and two customers. Returns
  them merged into `context`.
  """
  def configure_receivables!(%{operator: operator, accounts: accounts} = context) do
    {:ok, _setup} =
      Receivables.configure(operator, 73, %{
        receivable_account_id: accounts.receivable.id,
        income_account_id: accounts.income.id
      })

    series =
      for {key, code, kind, prefix} <- [
            {:invoice_series, "INV", "invoice", "INV-"},
            {:credit_series, "CN", "credit_note", "CN-"},
            {:payment_series, "RCP", "payment", "RCP-"}
          ],
          into: %{} do
        {:ok, series} =
          Receivables.create_series(operator, 73, %{
            code: code,
            name: "#{kind} series",
            kind: kind,
            prefix: prefix,
            number_width: 4
          })

        {key, series}
      end

    {:ok, standard} =
      Receivables.create_tax_code(operator, 73, %{
        code: "T10",
        name: "Ten percent",
        rate: "10",
        account_id: accounts.tax.id
      })

    {:ok, reduced} =
      Receivables.create_tax_code(operator, 73, %{
        code: "T6",
        name: "Six percent",
        rate: "6",
        account_id: accounts.tax.id
      })

    {:ok, customer} =
      Receivables.create_customer(operator, 73, %{
        code: "C001",
        name: "Example Customer",
        tax_identifier: "TAX-0001",
        line1: "1 Example Road",
        locality: "Example Town",
        country_iso: "XX",
        payment_terms_days: 30
      })

    {:ok, other_customer} =
      Receivables.create_customer(operator, 73, %{code: "C002", name: "Second Customer"})

    context
    |> Map.merge(series)
    |> Map.merge(%{
      standard_tax: standard,
      reduced_tax: reduced,
      customer: customer,
      other_customer: other_customer
    })
  end

  @doc "An Authz snapshot over the platform's, the ledger's, and receivables' capabilities."
  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
            {"finance/receivables", :bilimbi_finance_receivables, Receivables.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "finance-receivables-test"
    )
  end

  @doc """
  A scope signed in as the user, after granting the capabilities directly
  in the company. Tests are the only module code that calls the edge.
  """
  def sign_in!(%Scope{} = scope, company_id, user_id, capabilities) do
    for capability <- capabilities do
      {:ok, :stored} =
        Authz.put_principal_capability(scope, company_id, :user, user_id, capability, true)
    end

    Authentication.sign_in(scope, user_id, company_id)
  end

  @doc "Makes PostgreSQL run the deferred ledger and payment checks now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_receivables_tables! do
    # The migration is loaded at run time, so the call is dynamic.
    migration()
    |> apply(:statements, [[temporary: true]])
    |> Enum.each(&SQL.query!(Repo, &1, []))
  end
end
