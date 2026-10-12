defmodule Bilimbi.Finance.Payables.DocumentsTest do
  use Bilimbi.Finance.Payables.PayablesCase

  alias Bilimbi.Base.Tenancy.Authentication
  alias Ecto.Adapters.SQL

  describe "recording a bill" do
    test "stores a draft with its lines, tax lines, and totals", context do
      %{operator: operator, accounts: accounts, tax_code: tax_code} = context

      assert {:ok, bill} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-100", [
                   line(accounts.expense, "100.00", %{tax_code_id: tax_code.id}),
                   line(accounts.stock, "50.25", %{
                     tax_code_id: tax_code.id,
                     external_order_line_id: "order-7/line-2"
                   }),
                   line(accounts.expense, "10")
                 ])
               )

      assert %{
               document_type: "bill",
               status: "draft",
               document_number: nil,
               party_key: "P-1",
               party_document_number: "INV-100",
               due_date: ~D[2026-10-01],
               currency_code: "XTS",
               created_by_user_id: 91,
               created_by_impersonator_id: nil,
               created_at: %DateTime{},
               outstanding: nil
             } = bill

      assert [%{line_number: 1}, %{line_number: 2, external_order_line_id: "order-7/line-2"}, _] =
               bill.lines

      assert [%{tax_code: "T1", taxable_amount: taxable, tax_amount: tax}] = bill.tax_lines
      assert decimal?(taxable, "150.25") and decimal?(tax, "12.02")
      assert decimal?(bill.total_net, "160.25") and decimal?(bill.total, "172.27")
      assert {:ok, ^bill} = Payables.get_document(operator, 73, bill.id)
    end

    test "accepts string keys and the party's own tax figure", context do
      %{accounts: accounts, tax_code: tax_code} = context

      assert {:ok, bill} =
               Payables.create_bill(context.operator, 73, %{
                 "party_key" => "P-1",
                 "party_name" => "Party one",
                 "party_tax_id" => "TAX-ID-1",
                 "party_registration_id" => "REG-1",
                 "party_address" => "Address line",
                 "party_document_number" => "INV-1",
                 "document_date" => "2026-10-01",
                 "due_date" => "2026-10-31",
                 "lines" => [
                   %{
                     "description" => "Service",
                     "account_id" => accounts.expense.id,
                     "amount" => "33.33",
                     "tax_code_id" => tax_code.id
                   }
                 ],
                 "tax_lines" => [%{"tax_code_id" => tax_code.id, "tax_amount" => "2.66"}]
               })

      assert %{party_tax_id: "TAX-ID-1", due_date: ~D[2026-10-31]} = bill
      assert [%{tax_amount: stated}] = bill.tax_lines
      assert decimal?(stated, "2.66") and decimal?(bill.total, "35.99")
    end

    test "refuses lines with a wrong account, tax code, or amount", context do
      %{operator: operator, accounts: accounts, tax_code: tax_code} = context
      {:ok, _} = Ledger.update_account(operator, 73, accounts.stock.id, %{active: false})

      {:ok, inactive_code} =
        Payables.create_tax_code(operator, 73, %{
          code: "T0",
          name: "Retired",
          rate: "5",
          account_id: accounts.tax.id,
          active: false
        })

      for {bad_line, field, message} <- [
            {line(accounts.payable, "5"), :account_id,
             "must be an account of type asset or expense"},
            {line(accounts.stock, "5"), :account_id, "is inactive"},
            {%{line(accounts.expense, "5") | account_id: 999_999}, :account_id,
             "is not an account of this company"},
            {line(accounts.expense, "5", %{tax_code_id: 999_999}), :tax_code_id,
             "is not a tax code of this company"},
            {line(accounts.expense, "5", %{tax_code_id: inactive_code.id}), :tax_code_id,
             "is inactive"},
            {line(accounts.expense, "0"), :amount, "must be greater than 0"},
            {line(accounts.expense, "-1"), :amount, "must be greater than 0"},
            {line(accounts.expense, "1.001"), :amount, "has more than 2 decimal places"}
          ] do
        assert {:error, changeset} =
                 Payables.create_bill(
                   operator,
                   73,
                   bill("P-1", "INV-1", [
                     line(accounts.expense, "1", %{tax_code_id: tax_code.id}),
                     bad_line
                   ])
                 )

        assert %{lines: [%{}, %{^field => [^message]}]} = errors_on(changeset)
      end

      assert {:ok, []} = Payables.list_documents(operator, 73)
    end

    test "refuses a bill without lines, a party number, or a sensible due date", context do
      %{operator: operator, accounts: accounts, tax_code: tax_code} = context

      assert {:error, changeset} = Payables.create_bill(operator, 73, bill("P-1", "INV-1", []))
      assert %{lines: ["needs at least one line"]} = errors_on(changeset)

      assert {:error, changeset} =
               Payables.create_bill(operator, 73, bill("P-1", " ", [line(accounts.expense, "1")]))

      assert %{party_document_number: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-1", [line(accounts.expense, "1")], %{due_date: ~D[2026-09-30]})
               )

      assert %{due_date: ["cannot be before the document date"]} = errors_on(changeset)

      assert {:error, changeset} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-1", [line(accounts.expense, "1")], %{
                   tax_lines: [%{tax_code_id: tax_code.id, tax_amount: "1"}]
                 })
               )

      assert %{tax_lines: ["names a tax code no line uses"]} = errors_on(changeset)
    end

    test "records a party's document number once, until that bill is voided", context do
      %{operator: operator, accounts: accounts} = context
      attributes = bill("P-1", "INV-1", [line(accounts.expense, "1")])

      assert {:ok, first} = Payables.create_bill(operator, 73, attributes)
      assert {:error, changeset} = Payables.create_bill(operator, 73, attributes)

      assert %{party_document_number: ["is already recorded for this party"]} =
               errors_on(changeset)

      assert {:ok, _} = Payables.create_bill(operator, 73, %{attributes | party_key: "P-2"})

      assert {:ok, %{status: "voided"}} =
               Payables.void_document(operator, 73, first.id, %{void_reason: "Keyed twice"})

      assert {:ok, _} = Payables.create_bill(operator, 73, attributes)
    end

    test "needs the ledger's book, the grant, and a visible company", context do
      %{first_scope: system, second_scope: other, accounts: accounts} = context
      attributes = bill("P-1", "INV-1", [line(accounts.expense, "1")])

      sibling = TestFixtures.sign_in!(system, 74, 92, all_capabilities())
      assert {:error, :book_not_open} = Payables.create_bill(sibling, 74, attributes)

      viewer = TestFixtures.sign_in!(system, 73, 93, ["finance.payables.view"])
      assert {:error, :unauthorized} = Payables.create_bill(viewer, 73, attributes)
      assert {:error, :unauthorized} = Payables.create_bill(system, 73, attributes)

      outsider = TestFixtures.sign_in!(other, 75, 94, all_capabilities())
      assert {:error, :company_not_found} = Payables.create_bill(outsider, 73, attributes)
      assert {:error, :company_not_found} = Payables.list_documents(outsider, 73)
    end
  end

  describe "approval and posting" do
    setup context do
      %{accounts: accounts, tax_code: tax_code} = context

      {:ok, bill} =
        Payables.create_bill(
          context.operator,
          73,
          bill("P-1", "INV-1", [
            line(accounts.expense, "100", %{tax_code_id: tax_code.id}),
            line(accounts.stock, "20")
          ])
        )

      %{bill: bill}
    end

    test "approves, then posts a balanced ledger entry and numbers the bill", context do
      %{operator: operator, bill: bill, accounts: accounts} = context

      assert {:ok, %{status: "approved", approved_by_user_id: 91, approved_at: %DateTime{}}} =
               Payables.approve_document(operator, 73, bill.id)

      assert {:ok, posted} = Payables.post_document(operator, 73, bill.id)

      assert %{
               status: "posted",
               document_number: 1,
               posted_by_user_id: 91,
               posted_at: %DateTime{}
             } = posted

      assert posted.payable_account_id == accounts.payable.id
      assert decimal?(posted.outstanding, "128.00")

      assert {:ok, entry} = Ledger.get_entry(operator, 73, posted.entry_id)
      assert entry.entry_number == posted.entry_number
      assert %{entry_date: ~D[2026-10-01], reference: "INV-1"} = entry

      assert [
               {expense_id, expense_debit, _},
               {stock_id, stock_debit, _},
               {tax_id, tax_debit, _},
               {payable_id, _, payable_credit}
             ] = Enum.map(entry.lines, &{&1.account_id, &1.debit, &1.credit})

      assert {expense_id, stock_id, tax_id, payable_id} ==
               {accounts.expense.id, accounts.stock.id, accounts.tax.id, accounts.payable.id}

      assert decimal?(expense_debit, 100) and decimal?(stock_debit, 20)
      assert decimal?(tax_debit, 8) and decimal?(payable_credit, 128)
    end

    test "moves only forward, one step at a time", context do
      %{operator: operator, bill: bill} = context

      assert {:error, :not_approved} = Payables.post_document(operator, 73, bill.id)
      assert {:ok, _} = Payables.approve_document(operator, 73, bill.id)
      assert {:error, :not_draft} = Payables.approve_document(operator, 73, bill.id)
      assert {:ok, _} = Payables.post_document(operator, 73, bill.id)
      assert {:error, :not_approved} = Payables.post_document(operator, 73, bill.id)

      assert {:error, :not_voidable} =
               Payables.void_document(operator, 73, bill.id, %{void_reason: "Too late"})

      assert {:error, :document_not_found} = Payables.approve_document(operator, 73, -1)
      assert {:error, :document_not_found} = Payables.get_document(operator, 73, "1")
    end

    test "voids a draft or approved document with a reason and keeps it", context do
      %{operator: operator, bill: bill, accounts: accounts} = context

      assert {:error, changeset} = Payables.void_document(operator, 73, bill.id, %{})
      assert %{void_reason: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, %{status: "voided", voided_by_user_id: 91, void_reason: "Duplicate"}} =
               Payables.void_document(operator, 73, bill.id, %{void_reason: "Duplicate"})

      assert {:error, :not_draft} = Payables.approve_document(operator, 73, bill.id)

      second = bill("P-1", "INV-2", [line(accounts.expense, "1")])
      {:ok, second} = Payables.create_bill(operator, 73, second)
      {:ok, _} = Payables.approve_document(operator, 73, second.id)

      assert {:ok, %{status: "voided", approved_by_user_id: 91}} =
               Payables.void_document(operator, 73, second.id, %{void_reason: "Wrong party"})

      assert {:ok, [_, _]} = Payables.list_documents(operator, 73, status: "voided")
    end

    test "numbers posted bills without gaps; voided drafts take none", context do
      %{operator: operator, bill: bill, accounts: accounts} = context

      {:ok, _} = Payables.void_document(operator, 73, bill.id, %{void_reason: "Mistake"})

      numbers =
        for number <- ["INV-2", "INV-3"] do
          post_bill!(context, bill("P-1", number, [line(accounts.expense, "1")])).document_number
        end

      assert numbers == [1, 2]
    end

    test "separates recording, approving, and posting grants", context do
      %{first_scope: system, bill: bill} = context
      ledger = ~w(finance.ledger.view finance.ledger.entries.post)

      clerk =
        TestFixtures.sign_in!(system, 73, 95, ["finance.payables.documents.create" | ledger])

      approver = TestFixtures.sign_in!(system, 73, 96, ["finance.payables.documents.approve"])
      poster = TestFixtures.sign_in!(system, 73, 97, ["finance.payables.documents.post" | ledger])

      assert {:error, :unauthorized} = Payables.approve_document(clerk, 73, bill.id)
      assert {:error, :unauthorized} = Payables.post_document(approver, 73, bill.id)
      assert {:ok, %{approved_by_user_id: 96}} = Payables.approve_document(approver, 73, bill.id)
      assert {:ok, %{posted_by_user_id: 97}} = Payables.post_document(poster, 73, bill.id)
    end

    test "posting needs the ledger's posting grant too", context do
      %{first_scope: system, operator: operator, bill: bill} = context
      {:ok, _} = Payables.approve_document(operator, 73, bill.id)

      poster = TestFixtures.sign_in!(system, 73, 97, ["finance.payables.documents.post"])
      assert {:error, :unauthorized} = Payables.post_document(poster, 73, bill.id)
      assert {:ok, %{status: "approved"}} = Payables.get_document(operator, 73, bill.id)
    end

    test "records the operator behind an impersonated session", context do
      %{first_scope: system, bill: bill} = context
      TestFixtures.sign_in!(system, 73, 95, ["finance.payables.documents.approve"])

      impersonated =
        Authentication.sign_in(system, 95, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      assert {:ok, %{approved_by_user_id: 95, approved_by_impersonator_id: 91}} =
               Payables.approve_document(impersonated, 73, bill.id)
    end

    test "needs payables settings to post", context do
      %{first_scope: system} = context
      sibling = TestFixtures.sign_in!(system, 74, 92, all_capabilities())
      {:ok, _} = Ledger.open_book(sibling, 74, %{currency_code: "XTS", minor_units: 2})

      {:ok, expense} =
        Ledger.create_account(sibling, 74, %{
          code: "5000",
          name: "Expense",
          account_type: "expense"
        })

      {:ok, bill} =
        Payables.create_bill(sibling, 74, bill("P-1", "INV-1", [line(expense, "1")]))

      {:ok, _} = Payables.approve_document(sibling, 74, bill.id)
      assert {:error, :payables_not_configured} = Payables.post_document(sibling, 74, bill.id)
      assert {:error, :payables_not_configured} = Payables.get_settings(sibling, 74)
    end

    test "passes on the ledger's refusal of an account deactivated since", context do
      %{operator: operator, bill: bill, accounts: accounts} = context
      {:ok, _} = Payables.approve_document(operator, 73, bill.id)
      {:ok, _} = Ledger.update_account(operator, 73, accounts.stock.id, %{active: false})

      assert {:error, %Ecto.Changeset{}} = Payables.post_document(operator, 73, bill.id)
      assert {:ok, %{status: "approved"}} = Payables.get_document(operator, 73, bill.id)
      assert {:ok, []} = Ledger.list_entries(operator, 73)
    end
  end

  describe "debit notes" do
    setup context do
      %{accounts: accounts, tax_code: tax_code} = context

      bill =
        post_bill!(
          context,
          bill("P-1", "INV-1", [line(accounts.expense, "100", %{tax_code_id: tax_code.id})])
        )

      %{bill: bill}
    end

    test "correct a posted bill, posting the opposite entry", context do
      %{operator: operator, bill: bill, accounts: accounts, tax_code: tax_code} = context

      assert {:ok, note} =
               Payables.create_debit_note(operator, 73, bill.id, %{
                 document_date: ~D[2026-10-05],
                 party_document_number: "CN-1",
                 description: "Returned goods",
                 lines: [line(accounts.expense, "25", %{tax_code_id: tax_code.id})]
               })

      assert %{
               document_type: "debit_note",
               corrects_document_id: corrected,
               party_key: "P-1",
               party_name: "Party P-1"
             } = note

      assert corrected == bill.id
      assert decimal?(note.total, "27.00")

      {:ok, _} = Payables.approve_document(operator, 73, note.id)
      assert {:ok, posted} = Payables.post_document(operator, 73, note.id)
      assert %{document_number: 1, status: "posted"} = posted

      assert {:ok, %{outstanding: owed, debit_note_ids: [note_id]}} =
               Payables.get_document(operator, 73, bill.id)

      assert decimal?(owed, "81.00") and note_id == note.id

      {:ok, entry} = Ledger.get_entry(operator, 73, posted.entry_id)

      assert [{_, zero, credit}, {_, _, tax_credit}, {payable_id, payable_debit, _}] =
               Enum.map(entry.lines, &{&1.account_id, &1.debit, &1.credit})

      assert decimal?(zero, 0) and decimal?(credit, 25) and decimal?(tax_credit, 2)
      assert payable_id == accounts.payable.id and decimal?(payable_debit, 27)
    end

    test "post against the bill's own payable account after the setting changes", context do
      %{operator: operator, bill: bill, accounts: accounts} = context

      {:ok, _} =
        Payables.put_settings(operator, 73, %{payable_account_id: accounts.other_payable.id})

      {:ok, note} =
        Payables.create_debit_note(operator, 73, bill.id, %{
          document_date: ~D[2026-10-05],
          lines: [line(accounts.expense, "25")]
        })

      {:ok, _} = Payables.approve_document(operator, 73, note.id)
      assert {:ok, posted} = Payables.post_document(operator, 73, note.id)
      assert posted.payable_account_id == accounts.payable.id

      {:ok, entry} = Ledger.get_entry(operator, 73, posted.entry_id)
      assert accounts.payable.id in Enum.map(entry.lines, & &1.account_id)
      refute accounts.other_payable.id in Enum.map(entry.lines, & &1.account_id)
    end

    test "take string keys and keep the bill's party", context do
      %{operator: operator, bill: bill, accounts: accounts} = context

      assert {:ok, %{party_key: "P-1", party_name: "Party P-1"}} =
               Payables.create_debit_note(operator, 73, bill.id, %{
                 "party_key" => "P-2",
                 "party_name" => "Someone else",
                 "document_date" => "2026-10-05",
                 "lines" => [
                   %{
                     "description" => "Return",
                     "account_id" => accounts.expense.id,
                     "amount" => "1"
                   }
                 ]
               })
    end

    test "cannot exceed what is owed, now or when posted", context do
      %{operator: operator, bill: bill, accounts: accounts} = context
      note = %{document_date: ~D[2026-10-05], lines: [line(accounts.expense, "60")]}

      assert {:error, :exceeds_outstanding} =
               Payables.create_debit_note(operator, 73, bill.id, %{
                 note
                 | lines: [line(accounts.expense, "108.01")]
               })

      {:ok, first} = Payables.create_debit_note(operator, 73, bill.id, note)
      {:ok, second} = Payables.create_debit_note(operator, 73, bill.id, note)

      for id <- [first.id, second.id], do: {:ok, _} = Payables.approve_document(operator, 73, id)

      assert {:ok, _} = Payables.post_document(operator, 73, first.id)
      assert {:error, :exceeds_outstanding} = Payables.post_document(operator, 73, second.id)
    end

    test "need a posted bill and a date not before it", context do
      %{operator: operator, bill: bill, accounts: accounts} = context
      lines = [line(accounts.expense, "1")]

      {:ok, draft} = Payables.create_bill(operator, 73, bill("P-1", "INV-2", lines))

      assert {:error, :not_a_posted_bill} =
               Payables.create_debit_note(operator, 73, draft.id, %{
                 document_date: ~D[2026-10-05],
                 lines: lines
               })

      assert {:error, :document_not_found} =
               Payables.create_debit_note(operator, 73, -1, %{lines: lines})

      assert {:error, changeset} =
               Payables.create_debit_note(operator, 73, bill.id, %{
                 document_date: ~D[2026-09-30],
                 lines: lines
               })

      assert %{document_date: ["cannot be before the corrected bill's date"]} =
               errors_on(changeset)
    end
  end

  describe "listing" do
    test "filters and pages documents in date order", context do
      %{operator: operator, accounts: accounts} = context

      ids =
        for {key, number, date} <- [
              {"P-1", "A", ~D[2026-10-03]},
              {"P-2", "B", ~D[2026-10-01]},
              {"P-1", "C", ~D[2026-10-02]}
            ] do
          {:ok, bill} =
            Payables.create_bill(
              operator,
              73,
              bill(key, number, [line(accounts.expense, "1")], %{document_date: date})
            )

          bill.id
        end

      assert {:ok, documents} = Payables.list_documents(operator, 73)
      assert Enum.map(documents, & &1.party_document_number) == ["B", "C", "A"]

      assert {:ok, [%{party_document_number: "C"}, %{party_document_number: "A"}]} =
               Payables.list_documents(operator, 73, party_key: "P-1")

      assert {:ok, [%{party_document_number: "B"}]} =
               Payables.list_documents(operator, 73, limit: 1)

      [_, _, second] = ids

      assert {:ok, [%{party_document_number: "A"}]} =
               Payables.list_documents(operator, 73, after: {~D[2026-10-02], second})

      assert {:ok, [_]} =
               Payables.list_documents(operator, 73, from: ~D[2026-10-02], to: ~D[2026-10-02])

      assert {:ok, []} = Payables.list_documents(operator, 73, document_type: "debit_note")
    end

    test "refuses a malformed option", context do
      for option <- [
            [limit: 0],
            [limit: 501],
            [from: "2026-10-01"],
            [after: {~D[2026-10-01], 0}],
            [status: "open"],
            [document_type: :bill],
            [party_key: 7]
          ] do
        assert {:error, :invalid_option} = Payables.list_documents(context.operator, 73, option)
      end
    end
  end

  describe "the database" do
    setup context do
      %{accounts: accounts} = context
      posted = post_bill!(context, bill("P-1", "INV-1", [line(accounts.expense, "10")]))

      {:ok, draft} =
        Payables.create_bill(
          context.operator,
          73,
          bill("P-1", "INV-2", [line(accounts.expense, "5")])
        )

      %{posted: posted, draft: draft}
    end

    test "refuses to change, reopen, or delete a recorded document or its lines", context do
      %{posted: posted, draft: draft} = context

      for {sql, params, message} <- [
            {"UPDATE finance_payables_documents SET status = 'approved', approved_by_user_id = 91, party_name = 'x' WHERE id = $1",
             [draft.id], ~r/keeps what was recorded/},
            {"UPDATE finance_payables_documents SET party_name = 'x' WHERE id = $1", [draft.id],
             ~r/cannot go from draft to draft/},
            {"UPDATE finance_payables_documents SET total = 1 WHERE id = $1", [posted.id],
             ~r/cannot go from posted to posted/},
            {"UPDATE finance_payables_documents SET status = 'draft' WHERE id = $1", [posted.id],
             ~r/cannot go from posted to draft/},
            {"UPDATE finance_payables_documents SET status = 'posted' WHERE id = $1", [draft.id],
             ~r/cannot go from draft to posted/},
            {"DELETE FROM finance_payables_documents WHERE id = $1", [draft.id],
             ~r/finance payables keeps/},
            {"UPDATE finance_payables_document_lines SET amount = 11 WHERE document_id = $1",
             [posted.id], ~r/finance payables keeps/},
            {"DELETE FROM finance_payables_document_lines WHERE document_id = $1", [draft.id],
             ~r/finance payables keeps/}
          ] do
        # The savepoint keeps the test's own transaction usable afterwards.
        assert_raise Postgrex.Error, message, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, params) end)
        end
      end
    end

    # A draft's later transaction is refused too, which only a commit shows:
    # test/schema_contract_test.exs proves it.
    test "refuses a line added to a posted document", context do
      for document <- [context.posted] do
        assert_raise Postgrex.Error, ~r/already recorded: a line cannot be added/, fn ->
          Repo.transaction(fn ->
            SQL.query!(
              Repo,
              """
              INSERT INTO finance_payables_document_lines
                (tenant_id, company_id, document_id, line_number, description, account_id, amount)
              VALUES (41, 73, $1, 9, 'Late', $2, 1)
              """,
              [document.id, context.accounts.expense.id]
            )
          end)
        end
      end
    end

    test "refuses a document whose totals differ from its lines", context do
      SQL.query!(
        Repo,
        """
        WITH document AS (
          INSERT INTO finance_payables_documents
            (tenant_id, company_id, document_type, status, party_key, party_name,
             party_document_number, document_date, due_date, currency_code, total_net,
             total_tax, total, created_by_user_id)
          VALUES (41, 73, 'bill', 'draft', 'P-9', 'Raw', 'RAW-1', '2026-10-01', '2026-10-01',
                  'XTS', 10, 0, 10, 91)
          RETURNING id
        )
        INSERT INTO finance_payables_document_lines
          (tenant_id, company_id, document_id, line_number, description, account_id, amount)
        SELECT 41, 73, id, 1, 'Line', $1, 9 FROM document
        """,
        [context.accounts.expense.id]
      )

      assert_raise Postgrex.Error, ~r/totals differ from its lines/, fn ->
        TestFixtures.check_deferred_constraints!()
      end
    end

    test "records a document only as a draft, with the database's own time" do
      assert_raise Postgrex.Error, ~r/recorded as a draft/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            """
            INSERT INTO finance_payables_documents
              (tenant_id, company_id, document_type, status, party_key, party_name,
               party_document_number, document_date, due_date, currency_code, total_net,
               total_tax, total, created_by_user_id)
            VALUES (41, 73, 'bill', 'approved', 'P-9', 'Raw', 'RAW-1', '2026-10-01',
                    '2026-10-01', 'XTS', 10, 0, 10, 91)
            """,
            []
          )
        end)
      end
    end
  end
end
