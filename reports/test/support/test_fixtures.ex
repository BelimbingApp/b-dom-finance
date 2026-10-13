defmodule Bilimbi.Finance.Reports.TestFixtures do
  @moduledoc """
  A ledger with a small chart and postings, the settings table, and a
  contribution snapshot that knows the ledger's capabilities and the report
  sections setting. The ledger's tables and companies come from
  `Bilimbi.Finance.Ledger.TestFixtures`.
  """

  alias Bilimbi.Base.Authz.ContributionValidator, as: AuthzValidator
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.ContributionValidator, as: SettingsValidator
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reports.Contributions

  @capabilities [
    "finance.ledger.view",
    "finance.ledger.accounts.manage",
    "finance.ledger.entries.post"
  ]

  @doc """
  Tenant 41's company 73 with an open book in a test currency, a chart, and
  an operator (user 91) holding every ledger capability. Returns the
  ledger's context plus `operator` and `accounts` by code.
  """
  def setup_reports! do
    context = LedgerFixtures.setup_ledger!()
    SettingsFixtures.create_settings_table!()
    install_snapshot!()

    operator = LedgerFixtures.sign_in!(context.first_scope, 73, 91, @capabilities)
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(operator, 73)
    Map.merge(context, %{operator: operator, accounts: chart!(operator, 73)})
  end

  @doc """
  A chart in every account type, with one parent account and its child, so
  sections can cover sub-accounts: `{code, type, parent code}`.
  """
  def chart!(operator, company_id) do
    Enum.reduce(
      [
        {"1000", "asset", nil},
        {"1010", "asset", "1000"},
        {"1020", "asset", "1000"},
        {"1500", "asset", nil},
        {"2000", "liability", nil},
        {"2100", "liability", nil},
        {"3000", "equity", nil},
        {"4000", "income", nil},
        {"4100", "income", nil},
        {"5000", "expense", nil},
        {"5100", "expense", nil}
      ],
      %{},
      fn {code, type, parent}, accounts ->
        attributes = %{code: code, name: "Account #{code}", account_type: type}

        attributes =
          if parent, do: Map.put(attributes, :parent_id, accounts[parent].id), else: attributes

        {:ok, account} = Ledger.create_account(operator, company_id, attributes)
        Map.put(accounts, code, account)
      end
    )
  end

  @doc "Posts one entry of `{code, :debit | :credit, amount}` lines."
  def post!(operator, accounts, date, lines, company_id \\ 73) do
    {:ok, entry} =
      Ledger.post_entry(operator, company_id, %{
        entry_date: date,
        description: "Entry on #{date}",
        lines:
          for {code, side, amount} <- lines do
            %{:account_id => Map.fetch!(accounts, code).id, side => amount}
          end
      })

    entry
  end

  @doc "Stores the company's report sections."
  def put_sections!(sections, company_id \\ 73, tenant_id \\ 41) do
    {:ok, _value} =
      Settings.put(
        "finance.reports.sections",
        sections,
        Settings.Scope.company(company_id, tenant_id)
      )

    :ok
  end

  @doc "A snapshot with the ledger's capabilities and the reports' settings."
  def install_snapshot! do
    authz =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    settings = [
      %{
        descriptor: %{id: "finance/reports", otp_app: :bilimbi_finance_reports},
        payload: Contributions.contributions().settings
      }
    ]

    ContributionRegistry.put_consumers_for_test!(
      %{
        authz: AuthzValidator.validate_contributions!(authz),
        settings: SettingsValidator.validate_contributions!(settings)
      },
      "finance-reports-test"
    )
  end
end
