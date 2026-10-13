defmodule Bilimbi.Finance.Payables.TaxReportTest do
  use Bilimbi.Finance.Payables.PayablesCase

  test "sums posted documents per type and tax code, by document date", context do
    %{operator: operator, approver: approver, accounts: accounts, tax_code: tax_code} = context

    bill =
      post_bill!(
        context,
        bill("P-1", "B-1", [
          line(accounts.expense, "100", %{tax_code_id: tax_code.id}),
          line(accounts.expense, "40")
        ])
      )

    _second =
      post_bill!(
        context,
        bill("P-2", "B-2", [line(accounts.stock, "50", %{tax_code_id: tax_code.id})], %{
          document_date: ~D[2026-10-09]
        })
      )

    {:ok, note} =
      Payables.create_debit_note(operator, 73, bill.id, %{
        document_date: ~D[2026-10-05],
        lines: [line(accounts.expense, "25", %{tax_code_id: tax_code.id})]
      })

    {:ok, _approved} = Payables.approve_document(approver, 73, note.id)
    {:ok, _posted} = Payables.post_document(operator, 73, note.id)

    # Neither a draft nor a document dated outside the window counts.
    {:ok, _draft} =
      Payables.create_bill(
        operator,
        73,
        bill("P-3", "B-3", [line(accounts.expense, "70", %{tax_code_id: tax_code.id})])
      )

    _outside =
      post_bill!(
        context,
        bill("P-4", "B-4", [line(accounts.expense, "10", %{tax_code_id: tax_code.id})], %{
          document_date: ~D[2026-11-01]
        })
      )

    assert {:ok, [bills, notes]} =
             Payables.tax_totals(operator, 73, from: ~D[2026-10-01], to: ~D[2026-10-31])

    assert %{document_type: "bill", tax_code: "T1", document_count: 2} = bills
    assert {money(bills.taxable_amount), money(bills.tax_amount)} == {"150.00", "12.00"}
    assert bills.account_id == accounts.tax.id
    assert decimal?(bills.rate, 8)

    assert %{document_type: "debit_note", document_count: 1} = notes
    assert {money(notes.taxable_amount), money(notes.tax_amount)} == {"25.00", "2.00"}
  end

  test "reproduces a reading pinned to a ledger entry number", context do
    %{operator: operator, accounts: accounts, tax_code: tax_code} = context

    _first =
      post_bill!(
        context,
        bill("P-1", "B-1", [line(accounts.expense, "100", %{tax_code_id: tax_code.id})])
      )

    {:ok, %{through_entry_number: through}} = Ledger.account_totals(operator, 73)

    _backdated =
      post_bill!(
        context,
        bill("P-2", "B-2", [line(accounts.expense, "50", %{tax_code_id: tax_code.id})])
      )

    window = [from: ~D[2026-10-01], to: ~D[2026-10-31]]

    assert {:ok, [%{tax_amount: pinned}]} =
             Payables.tax_totals(operator, 73, window ++ [through_entry_number: through])

    assert {:ok, [%{tax_amount: now}]} = Payables.tax_totals(operator, 73, window)
    assert {money(pinned), money(now)} == {"8.00", "12.00"}
  end

  test "refuses malformed options and an actor without the view grant", context do
    assert {:error, :invalid_option} =
             Payables.tax_totals(context.operator, 73, from: ~D[2026-10-02], to: ~D[2026-10-01])

    viewer = TestFixtures.sign_in!(context.first_scope, 73, 93, [])
    assert {:error, :unauthorized} = Payables.tax_totals(viewer, 73)
  end

  defp money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()
end
