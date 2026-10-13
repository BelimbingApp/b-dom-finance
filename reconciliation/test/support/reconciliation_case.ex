defmodule Bilimbi.Finance.Reconciliation.ReconciliationCase do
  @moduledoc """
  A company with an open ledger book, a small chart, and one bank account
  mapped to its bank ledger account, for the module's suites. The
  `operator` does the work; the `reviewer`, another user with the same
  capabilities, finalises, since the company requires separation of duties.

  The contribution registry snapshot is process-global, so suites using this
  case do not run alongside other suites.
  """

  use ExUnit.CaseTemplate

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.TestFixtures

  using do
    quote do
      use Bilimbi.Base.Database.DataCase, async: false

      import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]
      import Bilimbi.Finance.Reconciliation.ReconciliationCase

      alias Bilimbi.Finance.Ledger
      alias Bilimbi.Finance.Reconciliation
      alias Bilimbi.Finance.Reconciliation.TestFixtures

      # After DataCase's setup, which checks out the sandbox connection.
      setup :setup_company
    end
  end

  @ledger ~w(finance.ledger.view finance.ledger.accounts.manage finance.ledger.entries.post finance.ledger.periods.manage)
  @reconciliation ~w(
    finance.reconciliation.view
    finance.reconciliation.bank-accounts.manage
    finance.reconciliation.statements.import
    finance.reconciliation.matches.manage
    finance.reconciliation.reconciliations.manage
    finance.reconciliation.reconciliations.finalise
    finance.reconciliation.statement-lines.post
    finance.reconciliation.statement-lines.manage
  )

  @doc "Every ledger and reconciliation capability the case grants."
  def all_capabilities, do: @ledger ++ @reconciliation

  @doc "The reconciliation capabilities alone."
  def reconciliation_capabilities, do: @reconciliation

  @doc "The case's company: see the moduledoc."
  def setup_company(_context) do
    context = TestFixtures.setup_reconciliation!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, all_capabilities())
    reviewer = TestFixtures.sign_in!(context.first_scope, 73, 96, all_capabilities())
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(operator, 73)

    accounts =
      for {key, code, type} <- [
            {:bank, "1010", "asset"},
            {:other_bank, "1020", "asset"},
            {:receivable, "1100", "asset"},
            {:payable, "2000", "liability"},
            {:equity, "3000", "equity"},
            {:income, "4000", "income"},
            {:interest, "4100", "income"},
            {:expense, "5000", "expense"},
            {:charges, "5100", "expense"}
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

    {:ok, bank_account} =
      Reconciliation.create_bank_account(operator, 73, %{
        name: "Operating account",
        ledger_account_id: accounts.bank.id,
        charges_account_id: accounts.charges.id,
        interest_account_id: accounts.interest.id,
        import_mapping: TestFixtures.mapping()
      })

    Map.merge(context, %{
      operator: operator,
      reviewer: reviewer,
      accounts: accounts,
      bank_account: bank_account
    })
  end

  @doc "Posts one entry of `{account key, :debit | :credit, amount}` lines on `date`."
  def post!(context, date, lines, extra \\ %{}) do
    {:ok, entry} =
      Ledger.post_entry(
        context.operator,
        73,
        Map.merge(
          %{
            entry_date: date,
            description: "Entry on #{date}",
            lines:
              for {key, side, amount} <- lines do
                %{:account_id => Map.fetch!(context.accounts, key).id, side => amount}
              end
          },
          extra
        )
      )

    entry
  end

  @doc "A deposit into the bank from income, or a payment out of it to an expense."
  def bank_entry!(context, date, amount, extra \\ %{}) do
    decimal = Decimal.new(amount)

    if Decimal.negative?(decimal),
      do:
        post!(
          context,
          date,
          [{:expense, :debit, Decimal.abs(decimal)}, {:bank, :credit, Decimal.abs(decimal)}],
          extra
        ),
      else: post!(context, date, [{:bank, :debit, decimal}, {:income, :credit, decimal}], extra)
  end

  @doc "Imports `rows` (date, description, reference, amount, balance) as `file_name`."
  def import!(context, rows, file_name \\ "statement.csv") do
    {:ok, statement} =
      Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
        file_name: file_name,
        content: TestFixtures.csv(rows)
      })

    statement
  end

  def decimal?(value, expected), do: Decimal.equal?(value, expected)
end
