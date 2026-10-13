defmodule Bilimbi.Finance.Payables.OwnershipTest do
  use Bilimbi.Finance.Payables.PayablesCase

  @module "finance/payables"

  setup context do
    %{accounts: accounts} = context
    bill = post_bill!(context, bill("P-1", "INV-1", [line(accounts.expense, "100")]))

    {:ok, payment} =
      pay(context, %{
        payment_date: ~D[2026-10-05],
        party_key: "P-1",
        paid_from_account_id: accounts.bank.id,
        allocations: [%{document_id: bill.id, amount: "100"}]
      })

    %{bill: bill, payment: payment}
  end

  defp owed(context, document) do
    {:ok, %{outstanding: outstanding}} = Payables.get_document(context.operator, 73, document.id)
    money(outstanding)
  end

  defp money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()

  describe "ledger ownership" do
    test "every posting names this module and its record as the entry's owner", context do
      %{operator: operator, bill: bill, payment: payment} = context

      assert {:ok, %{owner: %{module: @module, record: record}}} =
               Ledger.get_entry(operator, 73, bill.entry_id)

      assert record == "document:#{bill.id}"

      assert {:ok, %{owner: %{module: @module, record: record}}} =
               Ledger.get_entry(operator, 73, payment.entry_id)

      assert record == "payment:#{payment.id}"
    end

    test "a direct ledger reversal of a payment is refused; the module's reversal changes both",
         context do
      %{operator: operator, bill: bill, payment: payment} = context
      owner = %{module: @module, record: "payment:#{payment.id}"}

      assert {:error, {:owned_by, ^owner}} =
               Ledger.reverse_entry(operator, 73, payment.entry_id, %{
                 entry_date: ~D[2026-10-06],
                 description: "Undo"
               })

      assert {:ok, %{reversed_by_payment_id: nil}} =
               Payables.get_payment(operator, 73, payment.id)

      assert owed(context, bill) == "0.00"
      assert {:ok, [_bill_entry, _payment_entry]} = Ledger.list_entries(operator, 73)

      assert {:ok, reversal} =
               Payables.reverse_payment(operator, 73, payment.id, %{payment_date: ~D[2026-10-06]})

      assert {:ok, entry} = Ledger.get_entry(operator, 73, reversal.entry_id)
      assert %{owner: ^owner, reverses_entry_id: reverses} = entry
      assert reverses == payment.entry_id
      assert owed(context, bill) == "100.00"
    end

    test "an owner passed from outside the module reverses the entry, and the tie-out shows it",
         context do
      %{operator: operator, bill: bill, payment: payment} = context
      owner = %{module: @module, record: "payment:#{payment.id}"}

      assert {:ok, %{tied_out?: true}} =
               Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert {:ok, reversal} =
               Ledger.reverse_owned_entry(operator, 73, payment.entry_id, owner, %{
                 entry_date: ~D[2026-10-06],
                 description: "Reversed outside the module"
               })

      assert reversal.reverses_entry_id == payment.entry_id

      assert {:ok, %{reversed_by_payment_id: nil}} =
               Payables.get_payment(operator, 73, payment.id)

      assert owed(context, bill) == "0.00"

      assert {:ok, %{tied_out?: false, accounts: [row]}} =
               Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert money(row.subledger_balance) == "0.00"
      assert money(row.ledger_balance) == "100.00"
      assert money(row.difference) == "-100.00"
    end

    test "a ledger refusal of the reversal leaves no reversal payment either", context do
      %{operator: operator, first_scope: system, bill: bill, payment: payment} = context

      manager =
        TestFixtures.sign_in!(system, 73, 92, [
          "finance.ledger.view",
          "finance.ledger.periods.manage"
        ])

      {:ok, %{periods: [october | _]}} =
        Ledger.open_fiscal_year(manager, 73, %{start_date: ~D[2026-10-01]})

      {:ok, _} = Ledger.close_period(manager, 73, october.id)

      assert {:error, changeset} =
               Payables.reverse_payment(operator, 73, payment.id, %{payment_date: ~D[2026-10-06]})

      assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)

      assert {:ok, %{reversed_by_payment_id: nil}} =
               Payables.get_payment(operator, 73, payment.id)

      assert {:ok, [_only]} = Payables.list_payments(operator, 73)
      assert owed(context, bill) == "0.00"
      assert {:ok, [_bill_entry, _payment_entry]} = Ledger.list_entries(operator, 73)
    end
  end

  describe "tie_out_control_accounts/4" do
    test "ties the payable account out and shows every posting it does not know", context do
      %{operator: operator, accounts: accounts} = context
      _second = post_bill!(context, bill("P-2", "INV-9", [line(accounts.expense, "40")]))

      assert {:ok, report} = Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert %{
               through_entry_number: 3,
               currency_code: "XTS",
               owner_module: @module,
               tied_out?: true,
               accounts: [%{code: "2000", other_postings: []} = row]
             } = report

      assert row.account_id == accounts.payable.id
      assert money(row.subledger_balance) == "40.00"
      assert money(row.ledger_balance) == "40.00"
      assert money(row.owned_balance) == "40.00"
      assert money(row.difference) == "0.00"

      # A manual journal on the control account and a purchase another
      # module posted there as well are differences shown with their owner.
      {:ok, _manual} =
        Ledger.post_entry(operator, 73, %{
          entry_date: ~D[2026-10-15],
          description: "Manual accrual",
          lines: [
            %{account_id: accounts.expense.id, debit: "5"},
            %{account_id: accounts.payable.id, credit: "5"}
          ]
        })

      {:ok, _self_billed} =
        Ledger.post_entry(
          operator,
          73,
          %{
            entry_date: ~D[2026-10-16],
            description: "Self-billed e-invoice posted again",
            lines: [
              %{account_id: accounts.expense.id, debit: "40"},
              %{account_id: accounts.payable.id, credit: "40"}
            ]
          },
          owner: %{module: "finance/einvoice", record: "document:4"}
        )

      assert {:ok, later} = Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])
      assert %{through_entry_number: 5, tied_out?: false, accounts: [row]} = later
      assert money(row.subledger_balance) == "40.00"
      assert money(row.ledger_balance) == "85.00"
      assert money(row.owned_balance) == "40.00"
      assert money(row.difference) == "-45.00"
      assert money(later.total_difference) == "-45.00"

      assert [
               %{owner_module: nil, legacy: false} = manual,
               %{owner_module: "finance/einvoice", legacy: false} = other
             ] = row.other_postings

      assert money(manual.balance) == "5.00" and money(other.balance) == "40.00"

      assert {:ok, ^report} =
               Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31],
                 through_entry_number: 3
               )

      # A payment reversal through the module keeps the account tied out.
      {:ok, _} =
        Payables.reverse_payment(operator, 73, context.payment.id, %{
          payment_date: ~D[2026-10-20]
        })

      assert {:ok, %{accounts: [row]}} =
               Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert money(row.subledger_balance) == "140.00"
      assert money(row.owned_balance) == "140.00"
      assert money(row.difference) == "-45.00"
    end

    test "refuses a malformed option and needs the view grants", context do
      %{operator: operator, first_scope: system} = context

      for options <- [[through_entry_number: -1], [through_entry_number: "3"], [other: 1]] do
        assert {:error, :invalid_option} =
                 Payables.tie_out_control_accounts(operator, 73, ~D[2026-10-31], options)
      end

      clerk = TestFixtures.sign_in!(system, 73, 93, ["finance.payables.view"])

      assert {:error, :unauthorized} =
               Payables.tie_out_control_accounts(clerk, 73, ~D[2026-10-31])

      stranger = TestFixtures.sign_in!(system, 73, 94, ["finance.ledger.view"])

      assert {:error, :unauthorized} =
               Payables.tie_out_control_accounts(stranger, 73, ~D[2026-10-31])
    end
  end
end
