defmodule Bilimbi.Finance.Payroll.PayrollCase do
  @moduledoc """
  A company with an open ledger book, the accounts a payroll test posts to,
  the posting settings, the mappings of a small set of components and one
  claim category, and the stub source installed, for the module's suites.

  The contribution registry snapshot is process-global, so suites using this
  case do not run alongside other suites.
  """

  use ExUnit.CaseTemplate

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payroll
  alias Bilimbi.Finance.Payroll.StubPeopleSource
  alias Bilimbi.Finance.Payroll.TestFixtures

  using do
    quote do
      use Bilimbi.Base.Database.DataCase, async: false

      import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]
      import Bilimbi.Finance.Payroll.PayrollCase

      alias Bilimbi.Finance.Ledger
      alias Bilimbi.Finance.Payroll
      alias Bilimbi.Finance.Payroll.StubPeopleSource
      alias Bilimbi.Finance.Payroll.TestFixtures

      # After DataCase's setup, which checks out the sandbox connection.
      setup :setup_company
    end
  end

  @ledger ~w(finance.ledger.view finance.ledger.accounts.manage finance.ledger.entries.post finance.ledger.periods.manage)
  @payroll ~w(finance.payroll.view finance.payroll.settings.manage finance.payroll.postings.post)

  @doc "Every ledger and payroll capability the case grants."
  def all_capabilities, do: @ledger ++ @payroll

  @doc "The payroll capabilities alone."
  def payroll_capabilities, do: @payroll

  @doc "The case's company: see the moduledoc."
  def setup_company(_context) do
    context = TestFixtures.setup_payroll!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    StubPeopleSource.install!()
    on_exit(&StubPeopleSource.uninstall!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, all_capabilities())
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    setup_accounts!(Map.put(context, :operator, operator))
  end

  @doc "The case's chart of accounts, created by the context's operator."
  def setup_accounts!(%{operator: operator} = context) do
    accounts =
      for {key, code, type} <- [
            {:bank, "1010", "asset"},
            {:net_pay, "2100", "liability"},
            {:claims_payable, "2110", "liability"},
            {:fund_payable, "2200", "liability"},
            {:tax_payable, "2300", "liability"},
            {:equity, "3000", "equity"},
            {:salaries, "6000", "expense"},
            {:fund_expense, "6100", "expense"},
            {:travel, "6500", "expense"},
            {:old_expense, "6900", "expense"}
          ],
          into: %{} do
        {:ok, account} =
          Ledger.create_account(operator, 73, %{
            code: code,
            name: "Account #{code}",
            account_type: type
          })

        {key, account}
      end

    Map.put(context, :accounts, accounts)
  end

  @doc "Sets the posting accounts and the case's mappings: `basic` and `fund` components, and the `travel` claim category."
  def configure!(%{operator: operator, accounts: accounts} = context) do
    {:ok, settings} =
      Payroll.put_settings(operator, 73, %{
        net_pay_account_id: accounts.net_pay.id,
        claims_payable_account_id: accounts.claims_payable.id
      })

    mappings =
      for {code, direction, expense, liability} <- [
            {"basic", "earning", accounts.salaries, nil},
            {"fund", "deduction", nil, accounts.fund_payable},
            {"fund", "employer", accounts.fund_expense, accounts.fund_payable},
            {"tax", "deduction", nil, accounts.tax_payable}
          ] do
        {:ok, mapping} =
          Payroll.put_mapping(operator, 73, %{
            kind: "component",
            code: code,
            direction: direction,
            expense_account_id: expense && expense.id,
            liability_account_id: liability && liability.id
          })

        mapping
      end

    {:ok, travel} =
      Payroll.put_mapping(operator, 73, %{
        kind: "claim_category",
        code: "travel",
        direction: "claim",
        expense_account_id: accounts.travel.id
      })

    Map.merge(context, %{settings: settings, mappings: mappings ++ [travel]})
  end

  @doc "The case's run: basic earnings, a fund deduction and employer contribution, and tax."
  def run!(id \\ 1, extra \\ %{}) do
    StubPeopleSource.put_run!(
      Map.merge(
        %{
          id: id,
          components: [
            %{code: "basic", direction: "earning", amount: "5000.00"},
            %{code: "fund", direction: "deduction", amount: "550.00"},
            %{code: "fund", direction: "employer", amount: "650.00"},
            %{code: "tax", direction: "deduction", amount: "120.00"}
          ]
        },
        extra
      )
    )
  end

  def decimal?(value, expected), do: Decimal.equal?(value, expected)
end
