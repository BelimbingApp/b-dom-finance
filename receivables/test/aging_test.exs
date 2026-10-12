defmodule Bilimbi.Finance.Receivables.AgingTest do
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

  test "ages what each customer owes by days past due", context do
    %{operator: operator, customer: customer, other_customer: other} = context

    # Due 2026-10-31 (30-day terms), 2026-08-31, and 2026-06-30.
    current = issue!(context, customer, "100", ~D[2026-10-01])
    late = issue!(context, customer, "200", ~D[2026-08-01])
    older = issue!(context, customer, "300", ~D[2026-05-31])
    unrelated = issue!(context, other, "40", ~D[2026-10-01], ~D[2026-10-01])

    {:ok, _} =
      pay(context, customer, "50", [%{document_id: late.id, amount: "50"}], ~D[2026-10-02])

    {:ok, _} = credit!(context, older, "300", ~D[2026-10-03])

    assert {:ok, report} = Receivables.aged_receivables(operator, 73, ~D[2026-11-05])

    assert report.buckets == [
             %{from_days: nil, to_days: 0},
             %{from_days: 1, to_days: 30},
             %{from_days: 31, to_days: 60},
             %{from_days: 61, to_days: 90},
             %{from_days: 91, to_days: nil}
           ]

    assert %{currency_code: "XTS", minor_units: 2, as_of: ~D[2026-11-05]} = report

    # The credited invoice owes nothing and drops out.
    assert [
             %{code: "C001", documents: [late_row, current_row]} = first_customer,
             %{code: "C002", documents: [unrelated_row]}
           ] = report.customers

    assert {late_row.document_id, current_row.document_id, unrelated_row.document_id} ==
             {late.id, current.id, unrelated.id}

    assert %{days_overdue: 66, bucket: 3} = late_row
    assert %{days_overdue: 5, bucket: 1} = current_row
    assert %{days_overdue: 35, bucket: 2} = unrelated_row
    assert decimals(late_row.outstanding) == "150.00"

    assert Enum.map(first_customer.bucket_totals, &decimals/1) ==
             ["0.00", "100.00", "0.00", "150.00", "0.00"]

    assert decimals(first_customer.total) == "250.00"
    assert decimals(report.total) == "290.00"

    assert Enum.map(report.bucket_totals, &decimals/1) ==
             ["0.00", "100.00", "40.00", "150.00", "0.00"]
  end

  test "counts each event from its own date", context do
    %{operator: operator, customer: customer} = context
    invoice = issue!(context, customer, "100", ~D[2026-10-01])

    {:ok, payment} =
      pay(context, customer, "100", [%{document_id: invoice.id, amount: "100"}], ~D[2026-10-20])

    {:ok, _} =
      Receivables.reverse_payment(operator, 73, payment.id, %{
        reversal_date: ~D[2026-10-25],
        reason: "Returned"
      })

    total_on = fn date ->
      {:ok, report} = Receivables.aged_receivables(operator, 73, date)
      decimals(report.total)
    end

    assert total_on.(~D[2026-09-30]) == "0.00"
    assert total_on.(~D[2026-10-10]) == "100.00"
    assert total_on.(~D[2026-10-22]) == "0.00"
    assert total_on.(~D[2026-10-26]) == "100.00"

    {:ok, report} = Receivables.aged_receivables(operator, 73, ~D[2026-10-10])
    assert [%{documents: [%{bucket: 0, days_overdue: 0}]}] = report.customers
  end

  test "reproduces a report through its entry number and reconciles with the ledger",
       context do
    %{operator: operator, customer: customer, accounts: accounts} = context
    invoice = issue!(context, customer, "100", ~D[2026-10-01])

    {:ok, _} =
      pay(context, customer, "30", [%{document_id: invoice.id, amount: "30"}], ~D[2026-10-05])

    {:ok, report} = Receivables.aged_receivables(operator, 73, ~D[2026-10-31])
    assert decimals(report.total) == "70.00"

    # A back-dated invoice issued later changes the figures for that date...
    _backdated = issue!(context, customer, "500", ~D[2026-09-15])
    {:ok, later} = Receivables.aged_receivables(operator, 73, ~D[2026-10-31])
    assert decimals(later.total) == "570.00"

    # ...but the earlier report reproduces exactly through its entry number.
    assert {:ok, ^report} =
             Receivables.aged_receivables(operator, 73, ~D[2026-10-31],
               through_entry_number: report.through_entry_number
             )

    # The receivable account's trial balance agrees, then and now.
    for aged <- [report, later] do
      {:ok, trial} =
        Ledger.trial_balance(operator, 73, aged.as_of,
          through_entry_number: aged.through_entry_number
        )

      receivable = Enum.find(trial.rows, &(&1.id == accounts.receivable.id))
      assert Decimal.equal?(receivable.debit_balance, aged.total)
    end
  end

  test "takes its own buckets and refuses malformed options", context do
    %{operator: operator, customer: customer} = context
    issue!(context, customer, "10", ~D[2026-01-01], ~D[2026-01-01])

    assert {:ok, report} =
             Receivables.aged_receivables(operator, 73, ~D[2026-03-01], bucket_days: [7, 365])

    assert [
             %{from_days: nil},
             %{from_days: 1, to_days: 7},
             %{from_days: 8, to_days: 365},
             %{from_days: 366}
           ] =
             report.buckets

    assert [%{documents: [%{days_overdue: 59, bucket: 2}]}] = report.customers

    for option <- [
          [bucket_days: []],
          [bucket_days: [60, 30]],
          [bucket_days: [0]],
          [bucket_days: [30, 30]],
          [through_entry_number: -1],
          [through_entry_number: "1"]
        ] do
      assert {:error, :invalid_option} =
               Receivables.aged_receivables(operator, 73, ~D[2026-03-01], option)
    end

    viewer = TestFixtures.sign_in!(context.first_scope, 73, 94, [Receivables.view_capability()])
    assert {:error, :unauthorized} = Receivables.aged_receivables(viewer, 73, ~D[2026-03-01])
  end

  defp issue!(context, customer, price, issue_date, due_date \\ nil) do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: customer.id,
        issue_date: issue_date,
        due_date: due_date,
        lines: [%{description: "Service", quantity: "1", unit_price: price}]
      })

    {:ok, invoice} = Receivables.issue_document(context.operator, 73, draft.id)
    invoice
  end

  defp credit!(context, invoice, price, issue_date) do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "credit_note",
        series_id: context.credit_series.id,
        customer_id: invoice.customer_id,
        credited_document_id: invoice.id,
        issue_date: issue_date,
        lines: [%{description: "Credit", quantity: "1", unit_price: price}]
      })

    Receivables.issue_document(context.operator, 73, draft.id)
  end

  defp pay(context, customer, amount, allocations, date) do
    Receivables.record_payment(context.operator, 73, %{
      series_id: context.payment_series.id,
      customer_id: customer.id,
      payment_date: date,
      amount: amount,
      deposit_account_id: context.accounts.cash.id,
      allocations: allocations
    })
  end

  defp decimals(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()
end
