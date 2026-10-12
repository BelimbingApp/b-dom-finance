defmodule Bilimbi.Finance.Receivables.PaymentsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Receivables.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_receivables!() |> TestFixtures.configure_receivables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    first = issue_invoice!(context, "100")
    second = issue_invoice!(context, "50")
    Map.merge(context, %{first: first, second: second})
  end

  describe "recording" do
    test "settles invoices in part, numbers the payment, and posts the deposit", context do
      %{operator: operator, accounts: accounts, first: first, second: second} = context

      assert {:ok, payment} =
               pay(context, "120", [
                 %{document_id: first.id, amount: "100"},
                 %{document_id: second.id, amount: "20"}
               ])

      assert %{
               payment_number: 1,
               payment_reference: "RCP-0001",
               payment_date: ~D[2026-10-10],
               currency_code: "XTS",
               recorded_by_user_id: 91,
               recorded_at: %DateTime{},
               reversal: nil
             } = payment

      assert {:ok, ^payment} = Receivables.get_payment(operator, 73, payment.id)
      assert owed(context, first) == "0.00"
      assert owed(context, second) == "30.00"

      assert {:ok, entry} = Ledger.get_entry(operator, 73, payment.ledger_entry_id)
      assert entry.entry_number == payment.ledger_entry_number
      assert %{reference: "RCP-0001", entry_date: ~D[2026-10-10]} = entry

      assert [
               %{account_id: cash_id, debit: debit},
               %{account_id: receivable_id, credit: credit}
             ] = entry.lines

      assert {cash_id, receivable_id} == {accounts.cash.id, accounts.receivable.id}
      assert Decimal.equal?(debit, 120) and Decimal.equal?(credit, 120)

      assert {:ok, %{payment_number: 2, payment_reference: "RCP-0002"}} =
               pay(context, "30", [%{document_id: second.id, amount: "30"}])

      assert owed(context, second) == "0.00"
    end

    test "accepts string keys and values, as a form or an API sends them", context do
      assert {:ok, %{allocations: [%{document_id: id}]}} =
               Receivables.record_payment(context.operator, 73, %{
                 "series_id" => to_string(context.payment_series.id),
                 "customer_id" => to_string(context.customer.id),
                 "payment_date" => "2026-10-10",
                 "amount" => "25",
                 "deposit_account_id" => to_string(context.accounts.cash.id),
                 "allocations" => [
                   %{"document_id" => to_string(context.first.id), "amount" => "25"}
                 ]
               })

      assert id == context.first.id
    end

    test "refuses allocations that do not add up, overpay, repeat, or miss", context do
      %{first: first, second: second} = context

      assert {:error, changeset} = pay(context, "100", [%{document_id: first.id, amount: "90"}])
      assert %{allocations: ["do not add up to the payment amount"]} = errors_on(changeset)

      assert {:error, changeset} = pay(context, "101", [%{document_id: first.id, amount: "101"}])

      assert %{allocations: [%{document_id: ["owes less than the allocated amount"]}]} =
               errors_on(changeset)

      assert {:error, changeset} =
               pay(context, "20", [
                 %{document_id: second.id, amount: "10"},
                 %{document_id: second.id, amount: "10"}
               ])

      assert %{allocations: [%{}, %{document_id: ["is allocated twice"]}]} = errors_on(changeset)

      assert {:error, changeset} = pay(context, "10", [])
      assert %{allocations: ["needs at least one invoice"]} = errors_on(changeset)

      assert {:error, changeset} =
               pay(context, "1.001", [%{document_id: first.id, amount: "1.001"}])

      assert %{amount: [_], allocations: [%{amount: [_]}]} = errors_on(changeset)

      assert {:ok, []} = Receivables.list_payments(context.operator, 73)
    end

    test "refuses another customer's invoice, a draft, an earlier date, or a wrong account",
         context do
      %{operator: operator, first: first, accounts: accounts} = context

      assert {:error, changeset} =
               Receivables.record_payment(operator, 73, %{
                 series_id: context.payment_series.id,
                 customer_id: context.other_customer.id,
                 payment_date: ~D[2026-10-10],
                 amount: "10",
                 deposit_account_id: accounts.income.id,
                 allocations: [%{document_id: first.id, amount: "10"}]
               })

      assert %{
               deposit_account_id: ["must be a ledger asset account"],
               allocations: [%{document_id: ["is not an issued invoice of this customer"]}]
             } = errors_on(changeset)

      {:ok, draft} = create_invoice(context, "5")
      assert {:error, changeset} = pay(context, "5", [%{document_id: draft.id, amount: "5"}])
      assert %{allocations: [%{document_id: [_]}]} = errors_on(changeset)

      assert {:error, changeset} =
               pay(context, "5", [%{document_id: first.id, amount: "5"}], ~D[2026-09-30])

      assert %{allocations: [%{document_id: ["was issued after the payment date"]}]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Receivables.record_payment(operator, 73, %{
                 series_id: context.invoice_series.id,
                 customer_id: context.customer.id,
                 payment_date: ~D[2026-10-10],
                 amount: "5",
                 deposit_account_id: accounts.cash.id,
                 allocations: [%{document_id: first.id, amount: "5"}]
               })

      assert %{series_id: ["does not number payments"]} = errors_on(changeset)
    end

    test "are append-only", context do
      {:ok, _payment} = pay(context, "10", [%{document_id: context.first.id, amount: "10"}])

      for sql <- [
            "UPDATE finance_receivables_payments SET amount = 5",
            "DELETE FROM finance_receivables_allocations",
            "DELETE FROM finance_receivables_payments"
          ] do
        assert_raise Postgrex.Error, ~r/finance receivables keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end

    test "the database refuses a payment its allocations do not settle", context do
      {:ok, payment} = pay(context, "10", [%{document_id: context.first.id, amount: "10"}])

      SQL.query!(
        Repo,
        "INSERT INTO finance_receivables_allocations (tenant_id, company_id, payment_id, document_id, amount) VALUES (41, 73, $1, $2, 5)",
        [payment.id, context.second.id]
      )

      assert_raise Postgrex.Error, ~r/allocations do not equal its amount/, fn ->
        TestFixtures.check_deferred_constraints!()
      end
    end
  end

  describe "reversing" do
    test "posts the ledger reversal and reopens the invoices from its date", context do
      %{operator: operator, first: first} = context
      {:ok, payment} = pay(context, "60", [%{document_id: first.id, amount: "60"}])
      assert owed(context, first) == "40.00"

      assert {:ok, reversed} =
               Receivables.reverse_payment(operator, 73, payment.id, %{
                 reversal_date: ~D[2026-10-15],
                 reason: "Returned by the bank"
               })

      assert %{
               reversal: %{
                 reversal_date: ~D[2026-10-15],
                 reason: "Returned by the bank",
                 reversed_by_user_id: 91,
                 reversed_at: %DateTime{}
               }
             } = reversed

      assert owed(context, first) == "100.00"

      assert {:ok, %{reverses_entry_id: original}} =
               Ledger.get_entry(operator, 73, reversed.reversal.ledger_entry_id)

      assert original == payment.ledger_entry_id

      assert {:error, :already_reversed} =
               Receivables.reverse_payment(operator, 73, payment.id, %{
                 reversal_date: ~D[2026-10-15],
                 reason: "Again"
               })

      # The invoice can be settled again by a new payment.
      assert {:ok, _} = pay(context, "100", [%{document_id: first.id, amount: "100"}])
    end

    test "is dated on or after the payment and needs a reason", context do
      %{operator: operator} = context
      {:ok, payment} = pay(context, "10", [%{document_id: context.first.id, amount: "10"}])

      assert {:error, changeset} =
               Receivables.reverse_payment(operator, 73, payment.id, %{
                 reversal_date: ~D[2026-10-09],
                 reason: ""
               })

      assert %{reversal_date: [_], reason: [_]} = errors_on(changeset)
      assert {:error, :payment_not_found} = Receivables.reverse_payment(operator, 73, -1, %{})
    end
  end

  describe "after the setup's receivable account changes" do
    test "a credit note, payment, and reversal post to each invoice's recorded account",
         context do
      %{operator: operator, accounts: accounts, first: first, second: second} = context
      old = accounts.receivable.id

      {:ok, new} =
        Ledger.create_account(operator, 73, %{
          code: "1150",
          name: "Second receivable",
          account_type: "asset"
        })

      assert {:ok, %{receivable_account_id: new_id}} =
               Receivables.configure(operator, 73, %{receivable_account_id: new.id})

      assert new_id == new.id
      third = issue_invoice!(context, "70")
      assert {first.receivable_account_id, third.receivable_account_id} == {old, new.id}

      {:ok, draft} =
        Receivables.create_draft(operator, 73, %{
          kind: "credit_note",
          series_id: context.credit_series.id,
          customer_id: context.customer.id,
          credited_document_id: first.id,
          issue_date: ~D[2026-10-05],
          lines: [%{description: "Credit", quantity: "1", unit_price: "10"}]
        })

      assert {:ok, %{receivable_account_id: ^old, ledger_entry_id: credit_entry_id}} =
               Receivables.issue_document(operator, 73, draft.id)

      assert [%{account_id: ^old}] = credited_lines(operator, credit_entry_id)

      assert {:ok, payment} =
               pay(context, "110", [
                 %{document_id: first.id, amount: "90"},
                 %{document_id: third.id, amount: "20"}
               ])

      credits = credited_lines(operator, payment.ledger_entry_id)
      assert Enum.map(credits, & &1.account_id) == Enum.sort([old, new.id])
      assert credited(credits, old) == "90.00"
      assert credited(credits, new.id) == "20.00"
      assert owed(context, first) == "0.00"
      assert owed(context, third) == "50.00"

      # What is owed on each account's invoices is that account's balance.
      assert receivable_balances(context, [old, new.id]) == ["50.00", "50.00"]

      assert {:ok, _} =
               Receivables.reverse_payment(operator, 73, payment.id, %{
                 reversal_date: ~D[2026-10-15],
                 reason: "Returned by the bank"
               })

      assert receivable_balances(context, [old, new.id]) == ["140.00", "70.00"]
      assert owed(context, second) == "50.00"
    end
  end

  test "lists payments by customer and pages by ID", context do
    %{operator: operator} = context
    {:ok, first} = pay(context, "10", [%{document_id: context.first.id, amount: "10"}])
    {:ok, second} = pay(context, "10", [%{document_id: context.second.id, amount: "10"}])

    assert {:ok, [_, _]} =
             Receivables.list_payments(operator, 73, customer_id: context.customer.id)

    assert {:ok, []} =
             Receivables.list_payments(operator, 73, customer_id: context.other_customer.id)

    assert {:ok, [%{id: id}]} = Receivables.list_payments(operator, 73, after: first.id)
    assert id == second.id
    assert {:error, :invalid_option} = Receivables.list_payments(operator, 73, customer_id: "1")
  end

  defp pay(context, amount, allocations, date \\ ~D[2026-10-10]) do
    Receivables.record_payment(context.operator, 73, %{
      series_id: context.payment_series.id,
      customer_id: context.customer.id,
      payment_date: date,
      amount: amount,
      deposit_account_id: context.accounts.cash.id,
      allocations: allocations
    })
  end

  defp create_invoice(context, price) do
    Receivables.create_draft(context.operator, 73, %{
      kind: "invoice",
      series_id: context.invoice_series.id,
      customer_id: context.customer.id,
      issue_date: ~D[2026-10-01],
      lines: [%{description: "Service", quantity: "1", unit_price: price}]
    })
  end

  defp issue_invoice!(context, price) do
    {:ok, draft} = create_invoice(context, price)
    {:ok, invoice} = Receivables.issue_document(context.operator, 73, draft.id)
    invoice
  end

  defp credited_lines(operator, entry_id) do
    {:ok, entry} = Ledger.get_entry(operator, 73, entry_id)
    Enum.filter(entry.lines, &Decimal.gt?(&1.credit, 0))
  end

  defp credited(lines, account_id) do
    lines |> Enum.find(&(&1.account_id == account_id)) |> Map.fetch!(:credit) |> money()
  end

  # The accounts' ledger balances, after checking that the aged receivables
  # report adds up to them.
  defp receivable_balances(context, account_ids) do
    %{operator: operator} = context
    {:ok, report} = Receivables.aged_receivables(operator, 73, ~D[2026-10-31])

    {:ok, trial} =
      Ledger.trial_balance(operator, 73, report.as_of,
        through_entry_number: report.through_entry_number
      )

    balances =
      for id <- account_ids do
        case Enum.find(trial.rows, &(&1.id == id)) do
          nil -> Decimal.new(0)
          row -> Decimal.sub(row.debit_balance, row.credit_balance)
        end
      end

    assert Decimal.equal?(Enum.reduce(balances, &Decimal.add/2), report.total)
    Enum.map(balances, &money/1)
  end

  defp money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()

  defp owed(context, invoice) do
    {:ok, %{outstanding: outstanding}} =
      Receivables.get_document(context.operator, 73, invoice.id)

    outstanding |> Decimal.round(2) |> Decimal.to_string()
  end
end
