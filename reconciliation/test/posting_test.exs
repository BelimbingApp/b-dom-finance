defmodule Bilimbi.Finance.Reconciliation.PostingTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  setup context do
    statement =
      import!(context, [
        ["2026-10-20", "Monthly fee", "FEE", "-5.00", "995.00"],
        ["2026-10-31", "Credit interest", "", "1.25", "996.25"]
      ])

    [fee, interest] = statement.lines
    Map.merge(context, %{fee: fee, interest: interest})
  end

  test "posts a charge and interest through the ledger and matches each line to its entry",
       context do
    %{
      operator: operator,
      accounts: accounts,
      fee: fee,
      interest: interest,
      bank_account: bank_account
    } = context

    assert {:ok, %{entry: entry, match: match}} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

    assert entry.entry_date == ~D[2026-10-20]
    assert entry.description == "Monthly fee"
    assert entry.reference == "FEE"

    assert [
             %{account_id: charges, debit: debit},
             %{account_id: bank, credit: credit}
           ] = entry.lines

    assert charges == accounts.charges.id and bank == accounts.bank.id
    assert decimal?(debit, 5) and decimal?(credit, 5)

    assert match.statement_line_ids == [fee.id]
    assert [%{entry_id: entry_id, amount: amount}] = match.entries
    assert entry_id == entry.id and decimal?(amount, -5)
    assert match.note == "Posted from statement line as charge"

    assert {:ok, %{entry: interest_entry}} =
             Reconciliation.post_statement_line(operator, 73, interest.id, %{
               kind: "interest",
               description: "October interest"
             })

    assert interest_entry.description == "October interest"
    assert [%{account_id: bank2, debit: in_debit}, %{account_id: income}] = interest_entry.lines
    assert bank2 == accounts.bank.id and income == accounts.interest.id
    assert decimal?(in_debit, "1.25")

    assert {:ok, %{lines: [], entries: []}} =
             Reconciliation.unmatched_items(operator, 73, bank_account.id)

    assert {:error, :statement_line_matched} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})
  end

  test "refuses the wrong kind, a missing counter account, and a closed period, recording nothing",
       context do
    %{operator: operator, fee: fee, interest: interest, bank_account: bank_account} = context

    assert {:error, :not_a_charge} =
             Reconciliation.post_statement_line(operator, 73, interest.id, %{kind: "charge"})

    assert {:error, :not_interest} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "interest"})

    assert {:error, :invalid_kind} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "refund"})

    assert {:error, :statement_line_not_found} =
             Reconciliation.post_statement_line(operator, 73, 999, %{kind: "charge"})

    {:ok, _} =
      Reconciliation.update_bank_account(operator, 73, bank_account.id, %{charges_account_id: nil})

    assert {:error, :no_charges_account} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

    # A closed period: the ledger refuses and its changeset comes back, with
    # neither an entry nor a match recorded.
    {:ok, year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-01-01]})
    [first | _] = year.periods

    for period <- Enum.take(year.periods, 10) do
      {:ok, _} = Ledger.close_period(operator, 73, period.id, %{})
    end

    assert first.start_date == ~D[2026-01-01]

    assert {:error, changeset} =
             Reconciliation.post_statement_line(operator, 73, interest.id, %{kind: "interest"})

    assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)

    assert {:ok, %{lines: [_, _]}} = Reconciliation.unmatched_items(operator, 73, bank_account.id)
    assert {:ok, []} = Reconciliation.list_matches(operator, 73, bank_account.id)
  end

  test "needs the posting capabilities of both modules", context do
    %{first_scope: first, fee: fee} = context

    without_ledger =
      TestFixtures.sign_in!(first, 73, 92, [
        "finance.reconciliation.view",
        "finance.reconciliation.statement-lines.post",
        "finance.ledger.view"
      ])

    assert {:error, :unauthorized} =
             Reconciliation.post_statement_line(without_ledger, 73, fee.id, %{kind: "charge"})

    without_module =
      TestFixtures.sign_in!(first, 73, 93, [
        "finance.reconciliation.view",
        "finance.ledger.entries.post"
      ])

    assert {:error, :unauthorized} =
             Reconciliation.post_statement_line(without_module, 73, fee.id, %{kind: "charge"})
  end
end
