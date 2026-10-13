defmodule Bilimbi.Finance.Reconciliation.MatchingTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  setup context do
    # The books: a deposit, a payment, two half payments of one bill, and a
    # transfer that touches the other bank account too.
    deposit = bank_entry!(context, ~D[2026-10-01], "1000", %{reference: "DEP-1"})
    payment = bank_entry!(context, ~D[2026-10-02], "-45.50", %{reference: "INV-9"})
    half_one = bank_entry!(context, ~D[2026-10-04], "-30", %{reference: "BILL-4"})
    half_two = bank_entry!(context, ~D[2026-10-04], "-30", %{reference: "BILL-4"})

    transfer =
      post!(context, ~D[2026-10-06], [{:other_bank, :debit, "200"}, {:bank, :credit, "200"}])

    statement =
      import!(context, [
        ["2026-10-01", "Deposit", "DEP-1", "1000.00", "1000.00"],
        ["2026-10-03", "Card INV-9", "", "-45.50", "954.50"],
        ["2026-10-05", "Bill 4 combined", "BILL-4", "-60.00", "894.50"],
        ["2026-10-06", "Transfer out", "", "-200.00", "694.50"],
        ["2026-10-07", "Monthly fee", "", "-5.00", "689.50"]
      ])

    Map.merge(context, %{
      deposit: deposit,
      payment: payment,
      half_one: half_one,
      half_two: half_two,
      transfer: transfer,
      lines: statement.lines
    })
  end

  describe "unmatched items and suggestions" do
    test "lists both sides with the entry's amount on the account and suggests by amount, window, and reference",
         context do
      %{operator: operator, bank_account: bank_account, lines: lines} = context

      assert {:ok, unmatched} = Reconciliation.unmatched_items(operator, 73, bank_account.id)
      assert Enum.map(unmatched.lines, & &1.line_number) == [1, 2, 3, 4, 5]
      assert Enum.all?(unmatched.lines, &(&1.statement_number == 1))

      amounts =
        Map.new(
          unmatched.entries,
          &{&1.entry_number, &1.amount |> Decimal.normalize() |> Decimal.to_string(:normal)}
        )

      assert amounts == %{1 => "1000", 2 => "-45.5", 3 => "-30", 4 => "-30", 5 => "-200"}

      [deposit, payment, _bill, transfer, _fee] = lines
      assert unmatched.suggestions[deposit.id].entry_number == 1
      assert unmatched.suggestions[payment.id].entry_number == 2
      assert unmatched.suggestions[transfer.id].entry_number == 5
      assert map_size(unmatched.suggestions) == 3

      # Outside the account's window a same-amount entry is not suggested.
      {:ok, _} =
        Reconciliation.update_bank_account(operator, 73, bank_account.id, %{match_window_days: 0})

      assert {:ok, narrow} = Reconciliation.unmatched_items(operator, 73, bank_account.id)
      assert Map.keys(narrow.suggestions) == [deposit.id, transfer.id] |> Enum.sort()
    end

    test "prefers the entry whose reference the line names", context do
      %{operator: operator, bank_account: bank_account} = context
      # Two entries of 70 on the same day; the statement line names one.
      bank_entry!(context, ~D[2026-10-08], "-70", %{reference: "CHQ-100"})
      named = bank_entry!(context, ~D[2026-10-08], "-70", %{reference: "CHQ-101"})

      statement =
        import!(
          context,
          [["2026-10-08", "Cheque CHQ-101", "CHQ-101", "-70.00", "619.50"]],
          "chq.csv"
        )

      [line] = statement.lines

      assert {:ok, %{suggestions: suggestions}} =
               Reconciliation.unmatched_items(operator, 73, bank_account.id)

      assert suggestions[line.id].entry_id == named.id
    end
  end

  describe "matching" do
    test "one to one, one line to many entries, and many lines to one entry", context do
      %{operator: operator, bank_account: bank_account, lines: lines} = context
      [deposit, payment, bill, _transfer, _fee] = lines

      assert {:ok, match} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [deposit.id],
                 entry_ids: [context.deposit.id],
                 note: "Opening deposit"
               })

      assert match.match_number == 1
      assert match.status == "matched"
      assert match.statement_line_ids == [deposit.id]
      assert [%{entry_number: 1, amount: amount}] = match.entries
      assert decimal?(amount, 1000)
      assert [%{event_number: 1, action: "matched", recorded_by_user_id: 91}] = match.events
      assert match.matched_by_user_id == 91

      assert {:ok, combined} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [bill.id],
                 entry_ids: [context.half_one.id, context.half_two.id]
               })

      assert length(combined.entries) == 2

      # Two statement lines for one entry: a second import brings the deposit
      # of 45.50 the bank split in two.
      split = bank_entry!(context, ~D[2026-10-09], "90", %{reference: "SPLIT"})

      second =
        import!(
          context,
          [
            ["2026-10-09", "Part 1", "SPLIT", "40.00", "729.50"],
            ["2026-10-09", "Part 2", "SPLIT", "50.00", "779.50"]
          ],
          "split.csv"
        )

      assert {:ok, many} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: Enum.map(second.lines, & &1.id),
                 entry_ids: [split.id]
               })

      assert length(many.statement_line_ids) == 2

      assert {:ok, unmatched} = Reconciliation.unmatched_items(operator, 73, bank_account.id)
      assert Enum.map(unmatched.lines, & &1.line_number) == [2, 4, 5]
      assert Enum.map(unmatched.entries, & &1.entry_number) == [2, 5]

      assert {:ok, [_, _, _]} = Reconciliation.list_matches(operator, 73, bank_account.id)
      assert {:ok, %{match_number: 1}} = Reconciliation.get_match(operator, 73, match.id)
      assert payment.id not in match.statement_line_ids
    end

    test "refuses unbalanced, repeated, foreign, and empty selections", context do
      %{operator: operator, bank_account: bank_account, lines: lines, accounts: accounts} =
        context

      [deposit, payment, _bill, _transfer, fee] = lines

      assert {:error, {:unbalanced, statement_side, ledger_side}} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [fee.id],
                 entry_ids: [context.payment.id]
               })

      assert decimal?(statement_side, -5) and decimal?(ledger_side, "-45.5")

      {:ok, _} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [deposit.id],
          entry_ids: [context.deposit.id]
        })

      assert {:error, :statement_line_matched} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [deposit.id],
                 entry_ids: [context.deposit.id]
               })

      other_deposit =
        import!(context, [["2026-10-10", "Again", "", "1000.00", "1689.50"]], "again.csv")

      [again] = other_deposit.lines

      assert {:error, :entry_matched} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [again.id],
                 entry_ids: [context.deposit.id]
               })

      # An entry that never touched the bank account, and one that does not exist.
      elsewhere =
        post!(context, ~D[2026-10-02], [{:expense, :debit, "45.50"}, {:payable, :credit, "45.50"}])

      assert {:error, :entry_not_on_account} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [payment.id],
                 entry_ids: [elsewhere.id]
               })

      assert {:error, :entry_not_found} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [payment.id],
                 entry_ids: [999_999]
               })

      assert {:error, :invalid_selection} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [payment.id],
                 entry_ids: []
               })

      assert {:error, :invalid_selection} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: ["x"],
                 entry_ids: [1]
               })

      # A line of another bank account is not this account's.
      {:ok, other} =
        Reconciliation.create_bank_account(operator, 73, %{
          name: "Other",
          ledger_account_id: accounts.other_bank.id,
          import_mapping: TestFixtures.mapping()
        })

      assert {:error, :statement_line_not_found} =
               Reconciliation.match(operator, 73, other.id, %{
                 statement_line_ids: [payment.id],
                 entry_ids: [context.payment.id]
               })
    end

    test "a transfer between two bank accounts is matched on each", context do
      %{operator: operator, bank_account: bank_account, lines: lines, accounts: accounts} =
        context

      [_deposit, _payment, _bill, transfer, _fee] = lines

      {:ok, other} =
        Reconciliation.create_bank_account(operator, 73, %{
          name: "Savings",
          ledger_account_id: accounts.other_bank.id,
          import_mapping: TestFixtures.mapping()
        })

      {:ok, savings} =
        Reconciliation.import_statement(operator, 73, other.id, %{
          file_name: "savings.csv",
          content: TestFixtures.csv([["2026-10-06", "Transfer in", "", "200.00", "200.00"]])
        })

      assert {:ok, _} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [transfer.id],
                 entry_ids: [context.transfer.id]
               })

      assert {:ok, %{entries: [%{amount: amount}]}} =
               Reconciliation.match(operator, 73, other.id, %{
                 statement_line_ids: [hd(savings.lines).id],
                 entry_ids: [context.transfer.id]
               })

      assert decimal?(amount, 200)
    end

    test "needs the matches capability", context do
      %{first_scope: first, bank_account: bank_account, lines: lines} = context

      viewer =
        TestFixtures.sign_in!(first, 73, 92, [
          "finance.reconciliation.view",
          "finance.ledger.view"
        ])

      assert {:error, :unauthorized} =
               Reconciliation.match(viewer, 73, bank_account.id, %{
                 statement_line_ids: [hd(lines).id],
                 entry_ids: [context.deposit.id]
               })

      assert {:ok, %{suggestions: suggestions}} =
               Reconciliation.unmatched_items(viewer, 73, bank_account.id)

      assert map_size(suggestions) == 3
    end
  end

  describe "unmatching" do
    test "appends an event with its reason and frees both sides", context do
      %{operator: operator, bank_account: bank_account, lines: lines} = context
      [deposit | _] = lines

      {:ok, match} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [deposit.id],
          entry_ids: [context.deposit.id]
        })

      assert {:error, changeset} = Reconciliation.unmatch(operator, 73, match.id, %{reason: " "})
      assert %{reason: ["is needed to unmatch"]} = errors_on(changeset)

      assert {:ok, unmatched} =
               Reconciliation.unmatch(operator, 73, match.id, %{reason: "Wrong deposit"})

      assert unmatched.status == "unmatched"

      assert [
               %{event_number: 1, action: "matched"},
               %{
                 event_number: 2,
                 action: "unmatched",
                 reason: "Wrong deposit",
                 recorded_by_user_id: 91
               }
             ] = unmatched.events

      assert {:error, :match_not_standing} =
               Reconciliation.unmatch(operator, 73, match.id, %{reason: "Twice"})

      assert {:error, :match_not_found} =
               Reconciliation.unmatch(operator, 73, 999, %{reason: "None"})

      assert {:ok, items} = Reconciliation.unmatched_items(operator, 73, bank_account.id)
      assert deposit.id in Enum.map(items.lines, & &1.id)
      assert context.deposit.id in Enum.map(items.entries, & &1.entry_id)

      # Matched again: a new match, numbered after the first.
      assert {:ok, %{match_number: 2}} =
               Reconciliation.match(operator, 73, bank_account.id, %{
                 statement_line_ids: [deposit.id],
                 entry_ids: [context.deposit.id]
               })

      assert {:ok, [%{status: "unmatched"}, %{status: "matched"}]} =
               Reconciliation.list_matches(operator, 73, bank_account.id)
    end
  end

  describe "the database" do
    test "keeps matches and their events, and refuses a taken line, a taken entry, and an unbalanced match",
         context do
      %{operator: operator, bank_account: bank_account, lines: lines} = context
      [deposit, payment | _] = lines

      {:ok, match} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [deposit.id],
          entry_ids: [context.deposit.id]
        })

      for sql <- [
            "UPDATE finance_reconciliation_matches SET note = 'x'",
            "DELETE FROM finance_reconciliation_match_lines",
            "UPDATE finance_reconciliation_match_events SET action = 'unmatched'",
            "DELETE FROM finance_reconciliation_match_events"
          ] do
        assert_raise Postgrex.Error, ~r/finance reconciliation keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end

      # In the sandbox the match was written by this transaction, so the
      # unique index speaks first; the contract test proves the trigger.
      assert_raise Postgrex.Error, ~r/match_events_match_action_unique/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_reconciliation_match_events (tenant_id, company_id, match_id, action, recorded_by_user_id) VALUES (41, 73, $1, 'matched', 1)",
          [match.id]
        )
      end

      # A second match in this transaction over the same line, the same
      # entry, and then an unbalanced one.
      insert_match = fn ->
        %{rows: [[id]]} =
          SQL.query!(
            Repo,
            "INSERT INTO finance_reconciliation_matches (tenant_id, company_id, bank_account_id, matched_by_user_id) VALUES (41, 73, $1, 1) RETURNING id",
            [bank_account.id]
          )

        id
      end

      taken = insert_match.()

      assert_raise Postgrex.Error, ~r/statement line \d+ is already matched/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_reconciliation_match_lines (tenant_id, company_id, match_id, statement_line_id) VALUES (41, 73, $1, $2)",
          [taken, deposit.id]
        )
      end

      assert_raise Postgrex.Error, ~r/ledger entry \d+ is already matched on bank account/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_reconciliation_match_entries (tenant_id, company_id, match_id, bank_account_id, entry_id, entry_number, entry_date, description, amount) VALUES (41, 73, $1, $2, $3, 1, '2026-10-01', 'Deposit', 1000)",
          [taken, bank_account.id, context.deposit.id]
        )
      end

      SQL.query!(
        Repo,
        "INSERT INTO finance_reconciliation_match_lines (tenant_id, company_id, match_id, statement_line_id) VALUES (41, 73, $1, $2)",
        [taken, payment.id]
      )

      SQL.query!(
        Repo,
        "INSERT INTO finance_reconciliation_match_entries (tenant_id, company_id, match_id, bank_account_id, entry_id, entry_number, entry_date, description, amount) VALUES (41, 73, $1, $2, $3, 2, '2026-10-02', 'Payment', -40)",
        [taken, bank_account.id, context.payment.id]
      )

      SQL.query!(
        Repo,
        "INSERT INTO finance_reconciliation_match_events (tenant_id, company_id, match_id, action, recorded_by_user_id) VALUES (41, 73, $1, 'matched', 1)",
        [taken]
      )

      assert_raise Postgrex.Error,
                   ~r/statement side -45.5000 differs from ledger side -40.0000/,
                   fn ->
                     TestFixtures.check_deferred_constraints!()
                   end
    end
  end
end
