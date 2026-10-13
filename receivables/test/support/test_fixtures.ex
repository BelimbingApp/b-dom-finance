defmodule Bilimbi.Finance.Receivables.TestFixtures do
  @moduledoc """
  Receivables and ledger tables, authorization, two tenants' companies, and
  an open book with a small chart for module tests.

  The receivables tables are temporary copies built from the migrations' own
  statements (each migration's `statements(temporary: true)`, in version
  order), constraints
  and triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. `test/schema_contract_test.exs` checks the real
  migration itself. The ledger's tables come from its own fixtures.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Attachments.TestFixtures, as: AttachmentsFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Receivables
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @migration_files [
    {20_261_012_214_517, Bilimbi.Finance.Receivables.Migrations.CreateReceivables,
     "20261012214517_create_finance_receivables.exs"},
    {20_261_015_150_100, Bilimbi.Finance.Receivables.Migrations.ClaimEntries,
     "20261015150100_claim_finance_receivables_entries.exs"}
  ]

  @ledger ["finance.ledger.view", "finance.ledger.accounts.manage", "finance.ledger.entries.post"]
  @attachments ~w(finance.attachments.view finance.attachments.create finance.attachments.delete)

  @doc "The first migration's module, loaded from its file once."
  def migration, do: migrations() |> hd() |> elem(1)

  @doc "The module's migrations as `{version, module}` in version order, each loaded once."
  def migrations do
    for {version, module, file} <- @migration_files do
      unless Code.ensure_loaded?(module),
        do: Code.require_file(Path.join(@migrations_path, file))

      {version, module}
    end
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
    AttachmentsFixtures.create_artifacts_tables!()
    LedgerFixtures.create_ledger_tables!()
    AttachmentsFixtures.create_attachments_tables!()
    create_receivables_tables!()
    install_authz!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    operator = sign_in!(first, 73, 91, @ledger ++ @attachments ++ receivables_capabilities())

    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(operator, 73)

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

  @doc """
  An Authz snapshot over the platform's, Base Artifacts', the ledger's,
  attachments', and receivables' capabilities (the attachments fixtures'
  own, plus receivables').
  """
  def install_authz! do
    AttachmentsFixtures.install_authz!([
      {"finance/receivables", :bilimbi_finance_receivables, Receivables.Contributions}
    ])
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
    # The migrations are loaded at run time, so the calls are dynamic.
    for {_version, module} <- migrations(),
        statement <- apply(module, :statements, [[temporary: true]]) do
      SQL.query!(Repo, statement, [])
    end
  end
end
