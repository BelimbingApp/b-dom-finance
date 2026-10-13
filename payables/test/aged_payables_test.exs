defmodule Bilimbi.Finance.Payables.AgedPayablesTest do
  use Bilimbi.Finance.Payables.PayablesCase

  alias Ecto.Adapters.SQL

  setup context do
    %{accounts: accounts} = context

    overdue = post_bill!(context, bill("P-1", "A", [line(accounts.expense, "100")]))

    not_due =
      post_bill!(
        context,
        bill("P-1", "B", [line(accounts.expense, "50")], %{due_date: ~D[2026-11-15]})
      )

    older =
      post_bill!(
        context,
        bill("P-2", "C", [line(accounts.expense, "30")], %{
          document_date: ~D[2026-08-01],
          due_date: ~D[2026-08-10]
        })
      )

    {:ok, note} =
      Payables.create_debit_note(context.operator, 73, older.id, %{
        document_date: ~D[2026-09-01],
        lines: [line(accounts.expense, "5")]
      })

    {:ok, _} = Payables.approve_document(context.approver, 73, note.id)
    {:ok, _} = Payables.post_document(context.operator, 73, note.id)

    {:ok, payment} =
      pay(context, %{
        payment_date: ~D[2026-10-20],
        party_key: "P-1",
        paid_from_account_id: accounts.bank.id,
        allocations: [%{document_id: overdue.id, amount: "40"}]
      })

    %{overdue: overdue, not_due: not_due, older: older, payment: payment}
  end

  defp aged(context, as_of, options \\ []) do
    {:ok, report} = Payables.aged_payables(context.operator, 73, as_of, options)
    report
  end

  defp payment_to(context, bill, date) do
    %{
      payment_date: date,
      party_key: bill.party_key,
      paid_from_account_id: context.accounts.bank.id,
      allocations: [%{document_id: bill.id, amount: "100"}]
    }
  end

  defp amounts(values), do: Enum.map(values, &Decimal.to_string(Decimal.normalize(&1), :normal))

  test "groups what is owed by party and how long it is overdue", context do
    report = aged(context, ~D[2026-11-01])

    assert %{as_of: ~D[2026-11-01], bucket_days: [30, 60, 90]} = report
    assert [%{party_key: "P-1"} = first, %{party_key: "P-2"} = second] = report.parties

    assert [
             %{party_document_number: "A", days_overdue: 31, bucket: 2},
             %{party_document_number: "B", days_overdue: 0, bucket: 0}
           ] = first.documents

    assert amounts(Enum.map(first.documents, & &1.outstanding)) == ["60", "50"]
    assert amounts(first.buckets) == ["50", "0", "60", "0", "0"]
    assert amounts([first.total]) == ["110"]

    assert [%{party_document_number: "C", days_overdue: 83, bucket: 3, outstanding: owed}] =
             second.documents

    assert amounts([owed]) == ["25"]
    assert amounts(report.buckets) == ["50", "0", "60", "25", "0"]
    assert amounts([report.total]) == ["135"]
  end

  test "counts only what was dated on or before the date", context do
    report = aged(context, ~D[2026-10-10])

    assert [%{documents: [%{outstanding: before_payment}, _]}, _] =
             Enum.sort_by(report.parties, & &1.party_key)

    assert amounts([before_payment]) == ["100"]
    assert amounts([report.total]) == ["175"]

    assert %{parties: [%{party_key: "P-2", total: older}]} = aged(context, ~D[2026-08-15])
    assert amounts([older]) == ["30"]

    assert %{parties: [], total: nothing} = aged(context, ~D[2026-07-31])
    assert amounts([nothing]) == ["0"]
  end

  test "reproduces a report after a back-dated posting", context do
    %{accounts: accounts, overdue: overdue} = context
    report = aged(context, ~D[2026-11-01])

    {:ok, _} =
      pay(context, %{
        payment_date: ~D[2026-10-15],
        party_key: "P-1",
        paid_from_account_id: accounts.bank.id,
        allocations: [%{document_id: overdue.id, amount: "10"}]
      })

    assert amounts([aged(context, ~D[2026-11-01]).total]) == ["125"]

    assert aged(context, ~D[2026-11-01], through_entry_number: report.through_entry_number) ==
             report
  end

  test "counts a payment reversed by the date as unpaid", context do
    {:ok, _} =
      Payables.reverse_payment(context.operator, 73, context.payment.id, %{
        payment_date: ~D[2026-11-05]
      })

    assert amounts([aged(context, ~D[2026-11-01]).total]) == ["135"]
    assert amounts([aged(context, ~D[2026-11-05]).total]) == ["175"]
  end

  test "refuses what would leave a bill owed less than nothing on a later date", context do
    %{operator: operator, accounts: accounts} = context
    bill = post_bill!(context, bill("P-3", "X", [line(accounts.expense, "100")]))

    {:ok, payment} =
      pay(context, payment_to(context, bill, ~D[2026-10-10]))

    {:ok, _} = Payables.reverse_payment(operator, 73, payment.id, %{payment_date: ~D[2026-11-01]})

    assert {:ok, %{outstanding: owed}} = Payables.get_document(operator, 73, bill.id)
    assert amounts([owed]) == ["100"]

    assert {:error, :exceeds_outstanding} =
             Payables.create_debit_note(operator, 73, bill.id, %{
               document_date: ~D[2026-10-05],
               lines: [line(accounts.expense, "100")]
             })

    assert {:error, changeset} =
             pay(context, payment_to(context, bill, ~D[2026-10-05]))

    assert %{allocations: [%{amount: ["exceeds what is owed on the bill"]}]} =
             errors_on(changeset)

    assert {:ok, _} =
             Payables.create_debit_note(operator, 73, bill.id, %{
               document_date: ~D[2026-11-01],
               lines: [line(accounts.expense, "100")]
             })
  end

  test "lists a bill owed less than nothing as an exception that keeps the total whole",
       context do
    %{operator: operator, accounts: accounts} = context
    bill = post_bill!(context, bill("P-3", "X", [line(accounts.expense, "100")]))

    {:ok, payment} =
      pay(context, payment_to(context, bill, ~D[2026-10-10]))

    {:ok, _} = Payables.reverse_payment(operator, 73, payment.id, %{payment_date: ~D[2026-11-01]})

    # Another writer's second payment that the facade would have refused.
    {:ok, entry} =
      Ledger.post_entry(operator, 73, %{
        entry_date: ~D[2026-10-05],
        description: "Raw payment",
        lines: [
          %{account_id: accounts.payable.id, debit: "100"},
          %{account_id: accounts.bank.id, credit: "100"}
        ]
      })

    %{rows: [[raw_id]]} =
      SQL.query!(
        Repo,
        """
        INSERT INTO finance_payables_payments
          (tenant_id, company_id, payment_number, payment_date, party_key, party_name,
           paid_from_account_id, amount, currency_code, entry_id, entry_number,
           posted_by_user_id, posted_at)
        VALUES (41, 73, 1, '2026-10-05', 'P-3', 'Raw', $1, 100, 'XTS', $2, $3, 91, '2000-01-01')
        RETURNING id
        """,
        [accounts.bank.id, entry.id, entry.entry_number]
      )

    SQL.query!(
      Repo,
      """
      INSERT INTO finance_payables_payment_allocations
        (tenant_id, company_id, payment_id, line_number, document_id, amount)
      VALUES (41, 73, $1, 1, $2, 100)
      """,
      [raw_id, bill.id]
    )

    report = aged(context, ~D[2026-10-20])
    bill_id = bill.id

    assert [%{id: ^bill_id, party_key: "P-3", party_document_number: "X", outstanding: owed}] =
             report.exceptions

    assert amounts([owed, report.exceptions_total]) == ["-100", "-100"]
    refute Enum.any?(report.parties, &(&1.party_key == "P-3"))

    {:ok, trial_balance} = Ledger.trial_balance(operator, 73, ~D[2026-10-20])
    payable_id = accounts.payable.id
    assert %{credit_balance: held} = Enum.find(trial_balance.rows, &(&1.id == payable_id))
    assert Decimal.equal?(Decimal.add(report.total, report.exceptions_total), held)

    assert %{exceptions: [], exceptions_total: zero} = aged(context, ~D[2026-11-05])
    assert amounts([zero]) == ["0"]
  end

  test "takes the company's own bucket boundaries", context do
    report = aged(context, ~D[2026-11-01], bucket_days: [45])

    assert amounts(report.buckets) == ["50", "60", "25"]

    assert [%{documents: [%{bucket: 1}, %{bucket: 0}]}, %{documents: [%{bucket: 2}]}] =
             report.parties
  end

  test "refuses a malformed option and needs the view grant", context do
    for option <- [
          [through_entry_number: -1],
          [through_entry_number: "1"],
          [bucket_days: []],
          [bucket_days: [60, 30]],
          [bucket_days: [0, 30]],
          [bucket_days: [30, 30]]
        ] do
      assert {:error, :invalid_option} =
               Payables.aged_payables(context.operator, 73, ~D[2026-11-01], option)
    end

    poster =
      TestFixtures.sign_in!(context.first_scope, 73, 93, ["finance.payables.payments.post"])

    assert {:error, :unauthorized} = Payables.aged_payables(poster, 73, ~D[2026-11-01])
  end
end
