defmodule Bilimbi.Finance.Receivables.TaxReportTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Receivables.TestFixtures

  setup do
    context = TestFixtures.setup_receivables!() |> TestFixtures.configure_receivables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  describe "tax_totals/3" do
    test "sums issued documents per kind and tax code, and flags credit notes on earlier invoices",
         context do
      %{operator: operator, standard_tax: standard, reduced_tax: reduced} = context
      earlier = issue!(context, "invoice", ~D[2026-08-20], [taxed("200", standard)])
      first = issue!(context, "invoice", ~D[2026-09-02], [taxed("100", standard)])

      _second =
        issue!(context, "invoice", ~D[2026-09-15], [taxed("50", standard), taxed("30", reduced)])

      _untaxed = issue!(context, "invoice", ~D[2026-09-16], [line("70")])
      _same = issue!(context, "credit_note", ~D[2026-09-20], [taxed("10", standard)], first)
      _prior = issue!(context, "credit_note", ~D[2026-09-21], [taxed("20", standard)], earlier)
      {:ok, _draft} = draft(context, "invoice", ~D[2026-09-22], [taxed("999", standard)])
      _later = issue!(context, "invoice", ~D[2026-11-01], [taxed("40", standard)])

      assert {:ok, rows} =
               Receivables.tax_totals(operator, 73, from: ~D[2026-09-01], to: ~D[2026-10-31])

      assert [
               %{kind: "credit_note", credits_prior_period: false} = same,
               %{kind: "credit_note", credits_prior_period: true} = prior,
               %{kind: "invoice", credits_prior_period: false, tax_code: "T10"} = invoices,
               %{kind: "invoice", tax_code: "T6"} = reduced_row
             ] = rows

      assert {same.document_count, money(same.taxable_amount), money(same.tax_amount)} ==
               {1, "10.00", "1.00"}

      assert {money(prior.taxable_amount), money(prior.tax_amount)} == {"20.00", "2.00"}

      assert {invoices.document_count, money(invoices.taxable_amount), money(invoices.tax_amount),
              invoices.account_id} ==
               {2, "150.00", "15.00", context.accounts.tax.id}

      assert {money(reduced_row.taxable_amount), money(reduced_row.tax_amount)} ==
               {"30.00", "1.80"}
    end

    test "reproduces a reading pinned to a ledger entry number", context do
      %{operator: operator, standard_tax: standard} = context
      _first = issue!(context, "invoice", ~D[2026-09-02], [taxed("100", standard)])
      {:ok, %{through_entry_number: through}} = Ledger.account_totals(operator, 73)
      _backdated = issue!(context, "invoice", ~D[2026-09-03], [taxed("60", standard)])

      window = [from: ~D[2026-09-01], to: ~D[2026-09-30]]

      assert {:ok, [%{tax_amount: pinned}]} =
               Receivables.tax_totals(operator, 73, window ++ [through_entry_number: through])

      assert {:ok, [%{tax_amount: now}]} = Receivables.tax_totals(operator, 73, window)
      assert {money(pinned), money(now)} == {"10.00", "16.00"}

      assert {:ok, [line]} =
               Receivables.list_tax_lines(operator, 73, window ++ [through_entry_number: through])

      assert %{kind: "invoice", tax_code: "T10", issue_date: ~D[2026-09-02]} = line
    end

    test "refuses malformed options and an actor without the view grant", context do
      assert {:error, :invalid_option} =
               Receivables.tax_totals(context.operator, 73,
                 from: ~D[2026-10-01],
                 to: ~D[2026-09-01]
               )

      assert {:error, :invalid_option} =
               Receivables.tax_totals(context.operator, 73, through_entry_number: -1)

      viewer = TestFixtures.sign_in!(context.first_scope, 73, 93, [])
      assert {:error, :unauthorized} = Receivables.tax_totals(viewer, 73)
      assert {:error, :unauthorized} = Receivables.list_tax_lines(viewer, 73)
      assert {:error, :unauthorized} = Receivables.received_tax_totals(viewer, 73, [])
    end
  end

  describe "received_tax_totals/3" do
    test "shares the tax of payments received, less reversals, before an invoice falls due",
         context do
      %{operator: operator, standard_tax: standard, reduced_tax: reduced} = context

      invoice =
        issue!(context, "invoice", ~D[2026-08-10], [taxed("100", standard), taxed("50", reduced)])

      # Total 163.00: 100 + 10 tax and 50 + 3 tax.
      {:ok, _paid} = pay(context, invoice, "81.50", ~D[2026-09-05])
      {:ok, bounced} = pay(context, invoice, "16.30", ~D[2026-09-06])

      {:ok, _reversed} =
        Receivables.reverse_payment(operator, 73, bounced.id, %{
          reversal_date: ~D[2026-09-07],
          reason: "Cheque returned"
        })

      {:ok, _outside} = pay(context, invoice, "16.30", ~D[2026-11-01])

      assert {:ok, [standard_row, reduced_row]} =
               Receivables.received_tax_totals(operator, 73,
                 from: ~D[2026-09-01],
                 to: ~D[2026-10-31]
               )

      # Half the invoice was received and kept.
      assert %{measure: "received", tax_code: "T10", document_count: 1} = standard_row

      assert {money(standard_row.taxable_amount), money(standard_row.tax_amount)} ==
               {"50.00", "5.00"}

      assert %{measure: "received", tax_code: "T6"} = reduced_row

      assert {money(reduced_row.taxable_amount), money(reduced_row.tax_amount)} ==
               {"25.00", "1.50"}
    end

    test "makes an invoice still unpaid after the unpaid period due, and later credit notes deductible",
         context do
      %{operator: operator, standard_tax: standard} = context
      invoice = issue!(context, "invoice", ~D[2025-09-10], [taxed("100", standard)])
      {:ok, _part} = pay(context, invoice, "22", ~D[2025-12-01])

      _early_credit =
        issue!(context, "credit_note", ~D[2026-01-05], [taxed("20", standard)], invoice)

      # Twelve months from 10 September 2025 run from the 11th to 10
      # September 2026, so the tax on what is still owed is due on the 11th.
      {:ok, _late_payment} = pay(context, invoice, "11", ~D[2026-09-20])

      _late_credit =
        issue!(context, "credit_note", ~D[2026-09-25], [taxed("10", standard)], invoice)

      assert {:ok, rows} =
               Receivables.received_tax_totals(operator, 73,
                 from: ~D[2026-09-01],
                 to: ~D[2026-10-31]
               )

      assert [credited, unpaid] = rows
      assert %{measure: "credited_after_due", document_count: 1} = credited
      assert {money(credited.taxable_amount), money(credited.tax_amount)} == {"10.00", "1.00"}

      # 110 less 22 paid and 22 credited leaves 66, three fifths of it.
      assert %{measure: "unpaid", document_count: 1} = unpaid
      assert {money(unpaid.taxable_amount), money(unpaid.tax_amount)} == {"60.00", "6.00"}

      assert {:ok, []} =
               Receivables.received_tax_totals(operator, 73,
                 from: ~D[2026-09-01],
                 to: ~D[2026-09-10]
               )

      assert {:ok, [%{measure: "unpaid"}]} =
               Receivables.received_tax_totals(operator, 73,
                 from: ~D[2026-09-11],
                 to: ~D[2026-09-11]
               )
    end

    test "needs a bounded window and a valid unpaid period", context do
      assert {:error, :invalid_option} =
               Receivables.received_tax_totals(context.operator, 73, from: ~D[2026-09-01])

      assert {:error, :invalid_option} =
               Receivables.received_tax_totals(context.operator, 73,
                 from: ~D[2026-09-01],
                 to: ~D[2026-09-30],
                 unpaid_months: 0
               )
    end
  end

  defp line(price), do: %{description: "Service", quantity: "1", unit_price: price}
  defp taxed(price, tax_code), do: Map.put(line(price), :tax_code_id, tax_code.id)

  defp draft(context, kind, date, lines, credited \\ nil) do
    Receivables.create_draft(context.operator, 73, %{
      kind: kind,
      series_id:
        if(kind == "invoice", do: context.invoice_series.id, else: context.credit_series.id),
      customer_id: context.customer.id,
      credited_document_id: credited && credited.id,
      issue_date: date,
      lines: lines
    })
  end

  defp issue!(context, kind, date, lines, credited \\ nil) do
    {:ok, draft} = draft(context, kind, date, lines, credited)
    {:ok, document} = Receivables.issue_document(context.operator, 73, draft.id)
    document
  end

  defp pay(context, invoice, amount, date) do
    Receivables.record_payment(context.operator, 73, %{
      series_id: context.payment_series.id,
      customer_id: context.customer.id,
      payment_date: date,
      amount: amount,
      deposit_account_id: context.accounts.cash.id,
      allocations: [%{document_id: invoice.id, amount: amount}]
    })
  end

  defp money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()
end
