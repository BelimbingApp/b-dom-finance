defmodule Bilimbi.Finance.Receivables.OwnershipTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Receivables.TestFixtures

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @module "finance/receivables"

  setup do
    context = TestFixtures.setup_receivables!() |> TestFixtures.configure_receivables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    invoice = issue_invoice!(context, "100")

    {:ok, payment} =
      Receivables.record_payment(context.operator, 73, %{
        series_id: context.payment_series.id,
        customer_id: context.customer.id,
        payment_date: ~D[2026-10-10],
        amount: "100",
        deposit_account_id: context.accounts.cash.id,
        allocations: [%{document_id: invoice.id, amount: "100"}]
      })

    Map.merge(context, %{invoice: invoice, payment: payment})
  end

  describe "ledger ownership" do
    test "every posting names this module and its record as the entry's owner", context do
      %{operator: operator, invoice: invoice, payment: payment} = context

      assert {:ok, %{owner: %{module: @module, record: record}}} =
               Ledger.get_entry(operator, 73, invoice.ledger_entry_id)

      assert record == "document:#{invoice.id}"

      assert {:ok, %{owner: %{module: @module, record: record}}} =
               Ledger.get_entry(operator, 73, payment.ledger_entry_id)

      assert record == "payment:#{payment.id}"
    end

    test "a direct ledger reversal of a payment is refused; the module's reversal changes both",
         context do
      %{operator: operator, invoice: invoice, payment: payment} = context
      owner = %{module: @module, record: "payment:#{payment.id}"}

      assert {:error, {:owned_by, ^owner}} =
               Ledger.reverse_entry(operator, 73, payment.ledger_entry_id, %{
                 entry_date: ~D[2026-10-12],
                 description: "Undo"
               })

      assert {:ok, %{reversal: nil}} = Receivables.get_payment(operator, 73, payment.id)
      assert owed(context, invoice) == "0.00"
      assert {:ok, [_invoice_entry, _payment_entry]} = Ledger.list_entries(operator, 73)

      assert {:ok, %{reversal: reversal}} =
               Receivables.reverse_payment(operator, 73, payment.id, %{
                 reversal_date: ~D[2026-10-12],
                 reason: "Cheque bounced"
               })

      assert {:ok, entry} = Ledger.get_entry(operator, 73, reversal.ledger_entry_id)
      assert %{owner: ^owner, reverses_entry_id: reverses} = entry
      assert reverses == payment.ledger_entry_id
      assert owed(context, invoice) == "100.00"

      assert {:ok, %{reversed_by_entry_id: reversed_by}} =
               Ledger.get_entry(operator, 73, payment.ledger_entry_id)

      assert reversed_by == entry.id
    end

    test "an owner passed from outside the module reverses the entry, and the tie-out shows it",
         context do
      %{operator: operator, invoice: invoice, payment: payment} = context
      owner = %{module: @module, record: "payment:#{payment.id}"}

      assert {:ok, %{tied_out?: true}} =
               Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert {:ok, reversal} =
               Ledger.reverse_owned_entry(operator, 73, payment.ledger_entry_id, owner, %{
                 entry_date: ~D[2026-10-12],
                 description: "Reversed outside the module"
               })

      assert reversal.reverses_entry_id == payment.ledger_entry_id

      assert {:ok, %{reversal: nil}} = Receivables.get_payment(operator, 73, payment.id)
      assert owed(context, invoice) == "0.00"

      assert {:ok, %{tied_out?: false, total_difference: total, accounts: [row]}} =
               Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert money(row.subledger_balance) == "0.00"
      assert money(row.ledger_balance) == "100.00"
      assert money(row.difference) == "-100.00"
      assert money(total) == "-100.00"
    end

    test "a ledger refusal of the reversal leaves no payment reversal either", context do
      %{operator: operator, first_scope: system, invoice: invoice, payment: payment} = context

      manager =
        TestFixtures.sign_in!(system, 73, 92, [
          "finance.ledger.view",
          "finance.ledger.periods.manage"
        ])

      {:ok, %{periods: [october | _]}} =
        Ledger.open_fiscal_year(manager, 73, %{start_date: ~D[2026-10-01]})

      {:ok, _} = Ledger.close_period(manager, 73, october.id)

      assert {:error, changeset} =
               Receivables.reverse_payment(operator, 73, payment.id, %{
                 reversal_date: ~D[2026-10-12],
                 reason: "Cheque bounced"
               })

      assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)
      assert {:ok, %{reversal: nil}} = Receivables.get_payment(operator, 73, payment.id)
      assert owed(context, invoice) == "0.00"
      assert {:ok, [_invoice_entry, _payment_entry]} = Ledger.list_entries(operator, 73)
    end

    test "the ledger refuses a second entry for a record it already recognises", context do
      %{operator: operator, invoice: invoice, accounts: accounts} = context

      assert {:error, changeset} =
               Ledger.post_entry(
                 operator,
                 73,
                 %{
                   entry_date: ~D[2026-10-01],
                   description: "Again",
                   lines: [
                     %{account_id: accounts.receivable.id, debit: "100"},
                     %{account_id: accounts.income.id, credit: "100"}
                   ]
                 },
                 owner: %{module: @module, record: "document:#{invoice.id}"}
               )

      assert %{owner_record: ["already has an entry"]} = errors_on(changeset)
    end
  end

  describe "tie_out_control_accounts/4" do
    test "ties the receivable account out and shows every posting it does not know", context do
      %{operator: operator, accounts: accounts, invoice: invoice} = context
      second = issue_invoice!(context, "40")

      assert {:ok, report} = Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert %{
               as_of: ~D[2026-10-31],
               through_entry_number: 3,
               currency_code: "XTS",
               minor_units: 2,
               owner_module: @module,
               tied_out?: true,
               accounts: [row]
             } = report

      assert %{account_id: receivable_id, code: "1100", other_postings: []} = row
      assert receivable_id == accounts.receivable.id
      assert money(row.subledger_balance) == "40.00"
      assert money(row.ledger_balance) == "40.00"
      assert money(row.owned_balance) == "40.00"
      assert money(row.difference) == "0.00"
      assert money(report.total_difference) == "0.00"

      # A manual journal on the control account, and a sale another module
      # posted there too, are differences the report shows with their owner.
      {:ok, _manual} =
        Ledger.post_entry(operator, 73, %{
          entry_date: ~D[2026-10-15],
          description: "Manual adjustment",
          lines: [
            %{account_id: accounts.receivable.id, debit: "5"},
            %{account_id: accounts.income.id, credit: "5"}
          ]
        })

      {:ok, _einvoice} =
        Ledger.post_entry(
          operator,
          73,
          %{
            entry_date: ~D[2026-10-16],
            description: "E-invoice posted again",
            lines: [
              %{account_id: accounts.receivable.id, debit: "40"},
              %{account_id: accounts.income.id, credit: "40"}
            ]
          },
          owner: %{module: "finance/einvoice", record: "document:9"}
        )

      assert {:ok, later} = Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])
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

      # The earlier tie-out reproduces at its entry number; a date before
      # the postings leaves them out.
      assert {:ok, ^report} =
               Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31],
                 through_entry_number: 3
               )

      assert {:ok, %{tied_out?: true, accounts: [%{other_postings: []}]}} =
               Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-14])

      # A payment reversal made outside the module cannot happen; one made
      # through it keeps the account tied out.
      {:ok, _} =
        Receivables.reverse_payment(operator, 73, context.payment.id, %{
          reversal_date: ~D[2026-10-20],
          reason: "Bounced"
        })

      assert {:ok, %{accounts: [row]}} =
               Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31])

      assert money(row.subledger_balance) == "140.00"
      assert money(row.owned_balance) == "140.00"
      assert money(row.difference) == "-45.00"
      assert second.id != invoice.id
    end

    test "refuses a malformed option and needs the view grants", context do
      %{operator: operator, first_scope: system} = context

      for options <- [[through_entry_number: -1], [through_entry_number: "3"], [other: 1]] do
        assert {:error, :invalid_option} =
                 Receivables.tie_out_control_accounts(operator, 73, ~D[2026-10-31], options)
      end

      clerk = TestFixtures.sign_in!(system, 73, 93, ["finance.receivables.view"])

      assert {:error, :unauthorized} =
               Receivables.tie_out_control_accounts(clerk, 73, ~D[2026-10-31])

      stranger = TestFixtures.sign_in!(system, 73, 94, ["finance.ledger.view"])

      assert {:error, :unauthorized} =
               Receivables.tie_out_control_accounts(stranger, 73, ~D[2026-10-31])
    end
  end

  defp issue_invoice!(context, price) do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: ~D[2026-10-01],
        lines: [%{description: "Service", quantity: "1", unit_price: price}]
      })

    {:ok, invoice} = Receivables.issue_document(context.operator, 73, draft.id)
    invoice
  end

  defp owed(context, invoice) do
    {:ok, %{outstanding: outstanding}} =
      Receivables.get_document(context.operator, 73, invoice.id)

    money(outstanding)
  end

  defp money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()
end
