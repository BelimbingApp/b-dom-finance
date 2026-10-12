defmodule Bilimbi.Finance.Receivables.DocumentsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Receivables.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_receivables!() |> TestFixtures.configure_receivables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  describe "drafts" do
    test "compute line amounts and per-line tax, and sum tax lines per code", context do
      %{operator: operator, standard_tax: standard, reduced_tax: reduced} = context

      assert {:ok, draft} =
               create_invoice(context, [
                 %{
                   description: "Hours",
                   quantity: "3",
                   unit_price: "33.335",
                   tax_code_id: standard.id
                 },
                 %{
                   description: "Parts",
                   quantity: "1",
                   unit_price: "0.05",
                   tax_code_id: standard.id
                 },
                 %{
                   description: "Books",
                   quantity: "2",
                   unit_price: "12.50",
                   tax_code_id: reduced.id
                 },
                 %{description: "Exempt", quantity: "1", unit_price: "5"}
               ])

      assert %{status: "draft", document_number: nil, document_reference: nil} = draft
      assert {:ok, ^draft} = Receivables.get_document(operator, 73, draft.id)

      # 3 x 33.335 = 100.005 rounds half up to 100.01; its tax 10.001 to 10.00;
      # 0.05's tax 0.005 to 0.01; 25.00 at 6% is 1.50.
      assert amounts(draft.lines, :amount) == ["100.01", "0.05", "25.00", "5.00"]
      assert amounts(draft.lines, :tax_amount) == ["10.00", "0.01", "1.50", "0.00"]

      assert Enum.map(draft.lines, & &1.account_id) ==
               List.duplicate(context.accounts.income.id, 4)

      assert [
               %{tax_code: "T10", taxable_amount: taxable_10, tax_amount: tax_10},
               %{tax_code: "T6", taxable_amount: taxable_6, tax_amount: tax_6}
             ] = draft.tax_lines

      assert amounts([%{a: taxable_10}, %{a: tax_10}, %{a: taxable_6}, %{a: tax_6}], :a) ==
               ["100.06", "10.01", "25.00", "1.50"]

      assert amounts([draft], :subtotal) == ["130.06"]
      assert amounts([draft], :tax_total) == ["11.51"]
      assert amounts([draft], :total) == ["141.57"]
    end

    test "accept string keys and values, as a form or an API sends them", context do
      assert {:ok, %{lines: [line], tax_lines: [%{tax_code: "T10"}], total: total}} =
               Receivables.create_draft(context.operator, 73, %{
                 "kind" => "invoice",
                 "series_id" => to_string(context.invoice_series.id),
                 "customer_id" => to_string(context.customer.id),
                 "issue_date" => "2026-10-01",
                 "lines" => [
                   %{
                     "description" => "Service",
                     "quantity" => "2",
                     "unit_price" => "10",
                     "tax_code_id" => to_string(context.standard_tax.id)
                   }
                 ]
               })

      assert line.tax_code_id == context.standard_tax.id
      assert Decimal.equal?(total, "22.00")
    end

    test "replace their lines whole, or keep them when lines are omitted", context do
      %{operator: operator} = context
      {:ok, draft} = create_invoice(context, [line("100"), line("50")])

      assert {:ok, %{description: "Changed", lines: [_, _]}} =
               Receivables.update_draft(operator, 73, draft.id, %{description: "Changed"})

      assert {:ok, %{lines: [%{description: "Replaced"}], total: total}} =
               Receivables.update_draft(operator, 73, draft.id, %{
                 lines: [%{description: "Replaced", quantity: 1, unit_price: "7.5"}]
               })

      assert Decimal.equal?(total, "7.50")
    end

    test "refuse a line with a bad amount, a foreign or inactive tax code, or a wrong account",
         context do
      %{operator: operator, accounts: accounts, standard_tax: standard} = context
      {:ok, _} = Receivables.update_tax_code(operator, 73, standard.id, %{active: false})

      for {line, field} <- [
            {%{description: "x", quantity: "0", unit_price: "1"}, :quantity},
            {%{description: "x", quantity: "1", unit_price: "-1"}, :unit_price},
            {%{description: "x", quantity: "1.00001", unit_price: "1"}, :quantity},
            {%{description: "", quantity: "1", unit_price: "1"}, :description},
            {Map.put(line("1"), :tax_code_id, standard.id), :tax_code_id},
            {Map.put(line("1"), :tax_code_id, -1), :tax_code_id},
            {Map.put(line("1"), :account_id, accounts.cash.id), :account_id}
          ] do
        assert {:error, changeset} = create_invoice(context, [line])
        assert %{lines: [line_errors]} = errors_on(changeset)
        assert Map.has_key?(line_errors, field)
      end
    end

    test "refuse a series of another kind, an inactive customer, and a stray credit", context do
      %{operator: operator, credit_series: credit_series, customer: customer} = context

      assert {:error, changeset} =
               Receivables.create_draft(operator, 73, %{
                 kind: "invoice",
                 series_id: credit_series.id,
                 customer_id: customer.id
               })

      assert %{series_id: ["does not number invoice documents"]} = errors_on(changeset)

      {:ok, _} = Receivables.update_customer(operator, 73, customer.id, %{active: false})
      assert {:error, changeset} = create_invoice(context, [line("1")])
      assert %{customer_id: ["is an inactive customer"]} = errors_on(changeset)

      assert {:error, changeset} =
               Receivables.create_draft(operator, 73, %{
                 kind: "credit_note",
                 series_id: credit_series.id,
                 customer_id: context.other_customer.id
               })

      assert %{credited_document_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "are discarded, never deleted", context do
      %{operator: operator} = context
      {:ok, draft} = create_invoice(context, [line("10")])

      assert {:ok, %{status: "discarded", discarded_by_user_id: 91, discarded_at: %DateTime{}}} =
               Receivables.discard_draft(operator, 73, draft.id)

      assert {:error, :not_a_draft} = Receivables.update_draft(operator, 73, draft.id, %{})
      assert {:error, :not_a_draft} = Receivables.issue_document(operator, 73, draft.id)
      assert {:error, :document_not_found} = Receivables.discard_draft(operator, 73, -1)

      assert_raise Postgrex.Error, ~r/finance receivables keeps/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_receivables_documents", [])
      end
    end

    test "need the book open and receivables configured" do
      # A company with its own operator but neither book nor setup.
      {:ok, system} = Bilimbi.Base.Tenancy.scope(41)

      clerk =
        TestFixtures.sign_in!(
          system,
          74,
          92,
          TestFixtures.ledger_capabilities() ++ TestFixtures.receivables_capabilities()
        )

      assert {:error, :book_not_open} =
               Receivables.create_draft(clerk, 74, %{
                 kind: "invoice",
                 series_id: 1,
                 customer_id: 1
               })

      {:ok, _} = Ledger.open_book(clerk, 74, %{currency_code: "XTS", minor_units: 0})

      assert {:error, :not_configured} =
               Receivables.create_draft(clerk, 74, %{
                 kind: "invoice",
                 series_id: 1,
                 customer_id: 1
               })
    end
  end

  describe "issuing" do
    test "numbers, snapshots the party, and posts a balanced entry", context do
      %{operator: operator, accounts: accounts, customer: customer} = context

      {:ok, draft} =
        create_invoice(context, [
          Map.put(line("100"), :tax_code_id, context.standard_tax.id),
          Map.merge(line("40"), %{account_id: accounts.other_income.id})
        ])

      assert {:ok, invoice} = Receivables.issue_document(operator, 73, draft.id)

      assert %{
               status: "issued",
               document_number: 1,
               document_reference: "INV-0001",
               issue_date: ~D[2026-10-01],
               due_date: ~D[2026-10-31],
               party_name: "Example Customer",
               party_tax_identifier: "TAX-0001",
               party_line1: "1 Example Road",
               party_country_iso: "XX",
               issued_by_user_id: 91,
               issued_by_impersonator_id: nil,
               issued_at: %DateTime{}
             } = invoice

      assert Decimal.equal?(invoice.outstanding, "150.00")
      assert {:ok, ^invoice} = Receivables.get_document(operator, 73, invoice.id)

      assert {:ok, entry} = Ledger.get_entry(operator, 73, invoice.ledger_entry_id)
      assert entry.entry_number == invoice.ledger_entry_number

      assert %{entry_date: ~D[2026-10-01], reference: "INV-0001"} = entry
      assert entry.description == "Invoice INV-0001 to Example Customer"

      assert postings(entry) == [
               {accounts.receivable.id, "150.00", "0"},
               {accounts.income.id, "0", "100.00"},
               {accounts.other_income.id, "0", "40.00"},
               {accounts.tax.id, "0", "10.00"}
             ]

      # The party stays as issued when the customer changes.
      {:ok, _} = Receivables.update_customer(operator, 73, customer.id, %{name: "New Name"})

      assert {:ok, %{party_name: "Example Customer"}} =
               Receivables.get_document(operator, 73, invoice.id)
    end

    test "numbers each series 1, 2, 3, ... in issue order, skipping drafts", context do
      %{operator: operator} = context
      {:ok, first} = create_invoice(context, [line("1")])
      {:ok, second} = create_invoice(context, [line("2")])
      {:ok, discarded} = create_invoice(context, [line("3")])
      {:ok, _} = Receivables.discard_draft(operator, 73, discarded.id)

      assert {:ok, %{document_number: 1, document_reference: "INV-0001"}} =
               Receivables.issue_document(operator, 73, second.id)

      assert {:ok, %{document_number: 2}} = Receivables.issue_document(operator, 73, first.id)

      # A refused issue takes no number.
      {:ok, empty} = create_invoice(context, [])
      assert {:error, changeset} = Receivables.issue_document(operator, 73, empty.id)
      assert %{lines: ["needs at least one line"]} = errors_on(changeset)

      {:ok, third} = create_invoice(context, [line("3")])
      assert {:ok, %{document_number: 3}} = Receivables.issue_document(operator, 73, third.id)
    end

    test "is final: the facade and the database refuse any change after it", context do
      %{operator: operator} = context
      {:ok, draft} = create_invoice(context, [line("10")])
      {:ok, invoice} = Receivables.issue_document(operator, 73, draft.id)

      assert {:error, :not_a_draft} = Receivables.update_draft(operator, 73, invoice.id, %{})
      assert {:error, :not_a_draft} = Receivables.discard_draft(operator, 73, invoice.id)
      assert {:error, :not_a_draft} = Receivables.issue_document(operator, 73, invoice.id)

      for sql <- [
            "UPDATE finance_receivables_documents SET total = 1, subtotal = 1",
            "DELETE FROM finance_receivables_document_lines",
            "UPDATE finance_receivables_document_lines SET amount = 1"
          ] do
        assert_raise Postgrex.Error, ~r/never changed|no longer a draft/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end

    test "refuses an inactive account, customer, or series, and needs the ledger grant",
         context do
      %{operator: operator, first_scope: system, accounts: accounts} = context
      {:ok, draft} = create_invoice(context, [line("10")])

      issuer = TestFixtures.sign_in!(system, 73, 97, [Receivables.issue_documents_capability()])
      assert {:error, :unauthorized} = Receivables.issue_document(issuer, 73, draft.id)

      {:ok, _} = Ledger.update_account(operator, 73, accounts.income.id, %{active: false})

      {:ok, _} =
        Receivables.update_series(operator, 73, context.invoice_series.id, %{active: false})

      {:ok, _} = Receivables.update_customer(operator, 73, context.customer.id, %{active: false})

      assert {:error, changeset} = Receivables.issue_document(operator, 73, draft.id)

      assert %{
               lines: ["line 1 account is an inactive ledger account"],
               series_id: ["is inactive"],
               customer_id: ["is inactive"]
             } = errors_on(changeset)

      assert {:ok, %{status: "draft"}} = Receivables.get_document(operator, 73, draft.id)
      assert {:ok, []} = Ledger.list_entries(operator, 73)
    end

    test "records the operator behind an impersonated session", context do
      %{first_scope: system} = context

      TestFixtures.sign_in!(
        system,
        73,
        98,
        TestFixtures.ledger_capabilities() ++ TestFixtures.receivables_capabilities()
      )

      impersonated =
        Authentication.sign_in(system, 98, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      {:ok, draft} = create_invoice(context, [line("10")])

      assert {:ok, %{issued_by_user_id: 98, issued_by_impersonator_id: 91} = invoice} =
               Receivables.issue_document(impersonated, 73, draft.id)

      assert {:ok, %{posted_by_user_id: 98, posted_by_impersonator_id: 91}} =
               Ledger.get_entry(impersonated, 73, invoice.ledger_entry_id)
    end
  end

  describe "credit notes" do
    test "credit an issued invoice and post the mirror image", context do
      %{operator: operator, accounts: accounts} = context

      invoice =
        issue_invoice!(context, [Map.put(line("100"), :tax_code_id, context.standard_tax.id)])

      {:ok, draft} =
        credit_note(context, invoice, [Map.put(line("40"), :tax_code_id, context.standard_tax.id)])

      assert {:ok, credit} = Receivables.issue_document(operator, 73, draft.id)
      assert %{kind: "credit_note", document_reference: "CN-0001", due_date: nil} = credit
      assert credit.outstanding == nil

      assert {:ok, entry} = Ledger.get_entry(operator, 73, credit.ledger_entry_id)

      assert postings(entry) == [
               {accounts.receivable.id, "0", "44.00"},
               {accounts.income.id, "40.00", "0"},
               {accounts.tax.id, "4.00", "0"}
             ]

      assert {:ok, %{outstanding: owed}} = Receivables.get_document(operator, 73, invoice.id)
      assert Decimal.equal?(owed, "66.00")
    end

    test "credit no more than the invoice owes, of the same customer, not before it", context do
      %{operator: operator} = context
      invoice = issue_invoice!(context, [line("100")])

      {:ok, too_much} = credit_note(context, invoice, [line("100.01")])
      assert {:error, changeset} = Receivables.issue_document(operator, 73, too_much.id)
      assert %{total: ["exceeds what the credited invoice still owes"]} = errors_on(changeset)

      {:ok, early} =
        Receivables.update_draft(operator, 73, too_much.id, %{
          issue_date: ~D[2026-09-30],
          lines: [line("10")]
        })

      assert {:error, changeset} = Receivables.issue_document(operator, 73, early.id)
      assert %{issue_date: ["cannot be before the credited invoice's"]} = errors_on(changeset)

      assert {:error, changeset} =
               Receivables.create_draft(operator, 73, %{
                 kind: "credit_note",
                 series_id: context.credit_series.id,
                 customer_id: context.other_customer.id,
                 credited_document_id: invoice.id
               })

      assert %{credited_document_id: ["is not an issued invoice of this customer"]} =
               errors_on(changeset)

      {:ok, whole} = credit_note(context, invoice, [line("100")])
      assert {:ok, _} = Receivables.issue_document(operator, 73, whole.id)
      assert {:ok, %{outstanding: zero}} = Receivables.get_document(operator, 73, invoice.id)
      assert Decimal.equal?(zero, 0)
    end
  end

  describe "reading issued documents" do
    test "lists documents by filter and pages by ID", context do
      %{operator: operator} = context
      invoice = issue_invoice!(context, [line("10")])
      {:ok, draft} = create_invoice(context, [line("5")])

      assert {:ok, [%{id: id}]} = Receivables.list_documents(operator, 73, status: "issued")
      assert id == invoice.id
      assert {:ok, [_, _]} = Receivables.list_documents(operator, 73, kind: "invoice")
      assert {:ok, [%{id: ^id}]} = Receivables.list_documents(operator, 73, limit: 1)
      assert {:ok, [%{id: draft_id}]} = Receivables.list_documents(operator, 73, after: id)
      assert draft_id == draft.id

      for option <- [
            [status: "open"],
            [kind: :invoice],
            [limit: 0],
            [after: "1"],
            [customer_id: 0]
          ] do
        assert {:error, :invalid_option} = Receivables.list_documents(operator, 73, option)
      end
    end

    test "follows issued documents in issue order by ledger entry number", context do
      %{operator: operator} = context
      {:ok, older} = create_invoice(context, [line("1")])
      newer = issue_invoice!(context, [line("2")])
      {:ok, older} = Receivables.issue_document(operator, 73, older.id)

      assert {:ok, [first, second]} = Receivables.list_issued_documents(operator, 73)
      assert {first.id, second.id} == {newer.id, older.id}
      assert [%{description: _}] = first.lines

      assert {:ok, [only]} =
               Receivables.list_issued_documents(operator, 73,
                 after_entry_number: first.ledger_entry_number
               )

      assert only.id == older.id

      assert {:ok, []} =
               Receivables.list_issued_documents(operator, 73,
                 after_entry_number: older.ledger_entry_number
               )

      assert {:error, :invalid_option} =
               Receivables.list_issued_documents(operator, 73, after_entry_number: -1)
    end
  end

  defp create_invoice(context, lines) do
    Receivables.create_draft(context.operator, 73, %{
      kind: "invoice",
      series_id: context.invoice_series.id,
      customer_id: context.customer.id,
      issue_date: ~D[2026-10-01],
      lines: lines
    })
  end

  defp issue_invoice!(context, lines) do
    {:ok, draft} = create_invoice(context, lines)
    {:ok, invoice} = Receivables.issue_document(context.operator, 73, draft.id)
    invoice
  end

  defp credit_note(context, invoice, lines) do
    Receivables.create_draft(context.operator, 73, %{
      kind: "credit_note",
      series_id: context.credit_series.id,
      customer_id: invoice.customer_id,
      credited_document_id: invoice.id,
      issue_date: ~D[2026-10-05],
      lines: lines
    })
  end

  defp line(price), do: %{description: "Service", quantity: "1", unit_price: price}

  defp amounts(rows, field),
    do: Enum.map(rows, &(&1 |> Map.fetch!(field) |> Decimal.round(2) |> Decimal.to_string()))

  # Each ledger line as {account, debit, credit}, a zero side as "0".
  defp postings(entry),
    do: Enum.map(entry.lines, &{&1.account_id, side(&1.debit), side(&1.credit)})

  defp side(amount),
    do:
      if(Decimal.eq?(amount, 0), do: "0", else: amount |> Decimal.round(2) |> Decimal.to_string())
end
