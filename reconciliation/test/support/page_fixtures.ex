defmodule Bilimbi.Finance.Reconciliation.PageFixtures do
  @moduledoc """
  A company with a ledger book, a chart, and one bank account for the
  reconciliation pages' tests in `web_test/`: user 92 holds every capability
  and sets the scene; the signed-in user 91 holds only what each test grants.
  Compiled with the module's test support so the web tests need no
  `Code.require_file`.
  """

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Attachments.TestFixtures, as: AttachmentsFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.ReconciliationCase
  alias Bilimbi.Finance.Reconciliation.TestFixtures

  @view "finance.reconciliation.view"
  @ledger_view "finance.ledger.view"

  def view_capability, do: @view
  def ledger_view_capability, do: @ledger_view

  def setup_scene! do
    AttachmentsFixtures.create_artifacts_tables!()
    LedgerFixtures.create_ledger_tables!()
    AttachmentsFixtures.create_attachments_tables!()
    TestFixtures.create_reconciliation_tables!()
    AttachmentsFixtures.put_artifacts_root!()
    {:ok, scope} = Tenancy.scope(41)
    operator = TestFixtures.sign_in!(scope, 73, 92, ReconciliationCase.all_capabilities())
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    accounts =
      for {key, code, type} <- [
            {:bank, "1010", "asset"},
            {:other_bank, "1020", "asset"},
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

    %{scope: scope, operator: operator, accounts: accounts, bank_account: bank_account}
  end

  @doc "A deposit into the bank from income, or a payment out of it to an expense."
  def bank_entry!(scene, date, amount, extra \\ %{}) do
    decimal = Decimal.new(amount)
    absolute = Decimal.abs(decimal)

    lines =
      if Decimal.negative?(decimal),
        do: [
          %{account_id: scene.accounts.expense.id, debit: absolute},
          %{account_id: scene.accounts.bank.id, credit: absolute}
        ],
        else: [
          %{account_id: scene.accounts.bank.id, debit: absolute},
          %{account_id: scene.accounts.income.id, credit: absolute}
        ]

    {:ok, entry} =
      Ledger.post_entry(
        scene.operator,
        73,
        Map.merge(%{entry_date: date, description: "Entry on #{date}", lines: lines}, extra)
      )

    entry
  end

  def import!(scene, rows, file_name \\ "statement.csv") do
    {:ok, statement} =
      Reconciliation.import_statement(scene.operator, 73, scene.bank_account.id, %{
        file_name: file_name,
        content: TestFixtures.csv(rows)
      })

    statement
  end
end
