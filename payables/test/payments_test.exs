defmodule Bilimbi.Finance.Payables.PaymentsTest do
  use Bilimbi.Finance.Payables.PayablesCase

  alias Ecto.Adapters.SQL

  setup context do
    %{accounts: accounts} = context
    first = post_bill!(context, bill("P-1", "INV-1", [line(accounts.expense, "100")]))

    second =
      post_bill!(
        context,
        bill("P-1", "INV-2", [line(accounts.expense, "40")], %{document_date: ~D[2026-10-03]})
      )

    other = post_bill!(context, bill("P-2", "INV-1", [line(accounts.expense, "10")]))
    %{first: first, second: second, other: other}
  end

  defp payment(context, allocations, extra \\ %{}) do
    Map.merge(
      %{
        payment_date: ~D[2026-10-05],
        party_key: "P-1",
        paid_from_account_id: context.accounts.bank.id,
        reference: "TRANSFER-1",
        allocations: allocations
      },
      extra
    )
  end

  defp owed(context, document) do
    {:ok, %{outstanding: outstanding}} =
      Payables.get_document(context.operator, 73, document.id)

    outstanding
  end

  describe "posting a payment" do
    test "pays bills in part, posts the ledger entry, and numbers the payment", context do
      %{operator: operator, first: first, second: second, accounts: accounts} = context

      assert {:ok, payment} =
               Payables.post_payment(
                 operator,
                 73,
                 payment(context, [
                   %{document_id: first.id, amount: "60"},
                   %{document_id: second.id, amount: "40"}
                 ])
               )

      assert %{
               payment_number: 1,
               party_key: "P-1",
               party_name: "Party P-1",
               currency_code: "XTS",
               reference: "TRANSFER-1",
               reverses_payment_id: nil,
               reversed_by_payment_id: nil,
               posted_by_user_id: 91,
               posted_at: %DateTime{}
             } = payment

      assert decimal?(payment.amount, 100)
      assert [%{line_number: 1, document_id: first_id}, %{line_number: 2}] = payment.allocations
      assert first_id == first.id
      assert {:ok, ^payment} = Payables.get_payment(operator, 73, payment.id)

      assert decimal?(owed(context, first), 40) and decimal?(owed(context, second), 0)

      {:ok, entry} = Ledger.get_entry(operator, 73, payment.entry_id)

      assert [{payable_id, debit, _}, {bank_id, _, credit}] =
               Enum.map(entry.lines, &{&1.account_id, &1.debit, &1.credit})

      assert {payable_id, bank_id} == {accounts.payable.id, accounts.bank.id}
      assert decimal?(debit, 100) and decimal?(credit, 100)
      assert %{entry_date: ~D[2026-10-05], description: "Payment to Party P-1"} = entry
    end

    test "debits each bill's own payable account", context do
      %{operator: operator, first: first, accounts: accounts} = context

      {:ok, _} =
        Payables.put_settings(operator, 73, %{payable_account_id: accounts.other_payable.id})

      later = post_bill!(context, bill("P-1", "INV-3", [line(accounts.expense, "5")]))
      assert later.payable_account_id == accounts.other_payable.id

      {:ok, payment} =
        Payables.post_payment(
          operator,
          73,
          payment(context, [
            %{document_id: first.id, amount: "1"},
            %{document_id: later.id, amount: "5"}
          ])
        )

      {:ok, entry} = Ledger.get_entry(operator, 73, payment.entry_id)

      assert [accounts.payable.id, accounts.other_payable.id, accounts.bank.id] ==
               Enum.map(entry.lines, & &1.account_id)
    end

    test "refuses allocations that do not fit", context do
      %{operator: operator, first: first, second: second, other: other} = context

      {:ok, draft} =
        Payables.create_bill(
          operator,
          73,
          bill("P-1", "INV-9", [line(context.accounts.expense, "1")])
        )

      for {allocation, field, message} <- [
            {%{document_id: first.id, amount: "100.01"}, :amount,
             "exceeds what is owed on the bill"},
            {%{document_id: other.id, amount: "1"}, :document_id, "is another party's bill"},
            {%{document_id: draft.id, amount: "1"}, :document_id, "is not a posted bill"},
            {%{document_id: -1, amount: "1"}, :document_id, "is not a document of this company"},
            {%{document_id: first.id, amount: "0"}, :amount, "must be greater than 0"},
            {%{document_id: first.id, amount: "0.001"}, :amount, "has more than 2 decimal places"}
          ] do
        assert {:error, changeset} =
                 Payables.post_payment(operator, 73, payment(context, [allocation]))

        assert %{allocations: [%{^field => [^message]}]} = errors_on(changeset)
      end

      assert {:error, changeset} =
               Payables.post_payment(
                 operator,
                 73,
                 payment(context, [%{document_id: second.id, amount: "1"}], %{
                   payment_date: ~D[2026-10-02]
                 })
               )

      assert %{allocations: [%{document_id: ["is dated after the payment"]}]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Payables.post_payment(
                 operator,
                 73,
                 payment(context, [
                   %{document_id: first.id, amount: "1"},
                   %{document_id: first.id, amount: "1"}
                 ])
               )

      assert %{allocations: [%{}, %{document_id: ["is allocated twice"]}]} = errors_on(changeset)

      assert {:error, changeset} = Payables.post_payment(operator, 73, payment(context, []))
      assert %{allocations: ["needs at least one allocation"]} = errors_on(changeset)

      assert {:error, changeset} =
               Payables.post_payment(
                 operator,
                 73,
                 payment(context, [%{document_id: first.id, amount: "1"}], %{
                   paid_from_account_id: context.accounts.expense.id
                 })
               )

      assert %{paid_from_account_id: ["must be an account of type asset or liability"]} =
               errors_on(changeset)

      assert {:ok, []} = Payables.list_payments(operator, 73)
      assert {:ok, []} = Ledger.list_entries(operator, 73, from: ~D[2026-10-05])
    end

    test "needs the payments grant", context do
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 93, ["finance.payables.view"])

      assert {:error, :unauthorized} =
               Payables.post_payment(
                 viewer,
                 73,
                 payment(context, [%{document_id: context.first.id, amount: "1"}])
               )
    end
  end

  describe "reversal" do
    setup context do
      {:ok, payment} =
        Payables.post_payment(
          context.operator,
          73,
          payment(context, [%{document_id: context.first.id, amount: "70"}])
        )

      %{payment: payment}
    end

    test "reverses the ledger entry once and makes the bill owed again", context do
      %{operator: operator, payment: payment, first: first} = context

      assert {:ok, reversal} =
               Payables.reverse_payment(operator, 73, payment.id, %{payment_date: ~D[2026-10-06]})

      assert %{payment_number: 2, allocations: [], description: "Reversal of payment 1"} =
               reversal

      assert reversal.reverses_payment_id == payment.id
      assert decimal?(owed(context, first), 100)

      assert {:ok, %{reversed_by_payment_id: reversed_by}} =
               Payables.get_payment(operator, 73, payment.id)

      assert reversed_by == reversal.id

      assert {:ok, %{reversed_by_entry_id: entry_id}} =
               Ledger.get_entry(operator, 73, payment.entry_id)

      assert entry_id == reversal.entry_id

      assert {:error, :already_reversed} =
               Payables.reverse_payment(operator, 73, payment.id, %{payment_date: ~D[2026-10-06]})

      assert {:error, :reversal_not_reversible} =
               Payables.reverse_payment(operator, 73, reversal.id, %{payment_date: ~D[2026-10-06]})

      assert {:error, :payment_not_found} =
               Payables.reverse_payment(operator, 73, -1, %{payment_date: ~D[2026-10-06]})
    end

    test "refuses a date before the payment's", context do
      assert {:error, changeset} =
               Payables.reverse_payment(context.operator, 73, context.payment.id, %{
                 payment_date: ~D[2026-10-04]
               })

      assert %{payment_date: ["cannot be before the reversed payment's date"]} =
               errors_on(changeset)
    end
  end

  describe "listing" do
    test "filters and pages payments in date order", context do
      %{operator: operator, first: first, other: other} = context

      for {key, document, date} <- [
            {"P-1", first, ~D[2026-10-07]},
            {"P-2", other, ~D[2026-10-05]},
            {"P-1", first, ~D[2026-10-06]}
          ] do
        {:ok, _} =
          Payables.post_payment(
            operator,
            73,
            payment(context, [%{document_id: document.id, amount: "1"}], %{
              party_key: key,
              payment_date: date
            })
          )
      end

      assert {:ok, payments} = Payables.list_payments(operator, 73)
      assert Enum.map(payments, & &1.payment_number) == [2, 3, 1]

      assert {:ok, [%{payment_number: 3}, %{payment_number: 1}]} =
               Payables.list_payments(operator, 73, party_key: "P-1")

      assert {:ok, [%{payment_number: 2}]} = Payables.list_payments(operator, 73, limit: 1)

      assert {:ok, [%{payment_number: 2}]} =
               Payables.list_payments(operator, 73, document_id: other.id)

      assert {:error, :invalid_option} = Payables.list_payments(operator, 73, document_id: "1")
      assert {:error, :invalid_option} = Payables.list_payments(operator, 73, party_key: 1)
      assert {:error, :invalid_option} = Payables.list_payments(operator, 73, limit: 0)
    end
  end

  describe "the database" do
    setup context do
      {:ok, payment} =
        Payables.post_payment(
          context.operator,
          73,
          payment(context, [%{document_id: context.first.id, amount: "10"}])
        )

      %{payment: payment}
    end

    test "refuses to change or delete a payment or its allocations", %{payment: payment} do
      for {sql, params} <- [
            {"UPDATE finance_payables_payments SET amount = 11 WHERE id = $1", [payment.id]},
            {"DELETE FROM finance_payables_payments WHERE id = $1", [payment.id]},
            {"UPDATE finance_payables_payment_allocations SET amount = 11 WHERE payment_id = $1",
             [payment.id]},
            {"DELETE FROM finance_payables_payment_allocations WHERE payment_id = $1",
             [payment.id]}
          ] do
        assert_raise Postgrex.Error, ~r/finance payables keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, params) end)
        end
      end
    end

    test "refuses a payment whose allocations differ from its amount", context do
      SQL.query!(
        Repo,
        """
        INSERT INTO finance_payables_payment_allocations
          (tenant_id, company_id, payment_id, line_number, document_id, amount)
        VALUES (41, 73, $1, 2, $2, 1)
        """,
        [context.payment.id, context.second.id]
      )

      assert_raise Postgrex.Error, ~r/allocations differ from its amount/, fn ->
        TestFixtures.check_deferred_constraints!()
      end
    end

    test "numbers payments itself, whatever a writer sends", context do
      %{rows: [[number]]} =
        SQL.query!(
          Repo,
          """
          INSERT INTO finance_payables_payments
            (tenant_id, company_id, payment_number, payment_date, party_key, party_name,
             paid_from_account_id, amount, currency_code, reverses_payment_id, entry_id,
             entry_number, posted_by_user_id, posted_at)
          VALUES (41, 73, 1, '2026-10-05', 'P-1', 'Raw', $1, 10, 'XTS', $2, 1, 1, 91,
                  '2000-01-01')
          RETURNING payment_number
          """,
          [context.accounts.bank.id, context.payment.id]
        )

      assert number == 2
    end
  end
end
