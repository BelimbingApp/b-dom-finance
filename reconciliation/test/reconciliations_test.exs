defmodule Bilimbi.Finance.Reconciliation.ReconciliationsTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # October's books: a deposit the bank saw, a payment the bank saw, a cheque
  # written on the 30th that clears in November, and a deposit in transit.
  # October's statement: the deposit, the payment, and a bank charge the
  # books do not have.
  setup context do
    deposit = bank_entry!(context, ~D[2026-10-01], "1000")
    payment = bank_entry!(context, ~D[2026-10-05], "-45.50")
    cheque = bank_entry!(context, ~D[2026-10-30], "-120")
    in_transit = bank_entry!(context, ~D[2026-10-31], "300")

    october =
      import!(context, [
        ["2026-10-01", "Deposit", "", "1000.00", "1000.00"],
        ["2026-10-06", "Card", "", "-45.50", "954.50"],
        ["2026-10-20", "Monthly fee", "", "-5.00", "949.50"]
      ])

    [deposit_line, payment_line, fee_line] = october.lines

    match! = fn line, entry ->
      {:ok, match} =
        Reconciliation.match(context.operator, 73, context.bank_account.id, %{
          statement_line_ids: [line.id],
          entry_ids: [entry.id]
        })

      match
    end

    match!.(deposit_line, deposit)
    match!.(payment_line, payment)

    Map.merge(context, %{
      cheque: cheque,
      in_transit: in_transit,
      fee_line: fee_line,
      october: october,
      match!: match!
    })
  end

  describe "the figures" do
    test "show both balances, what is unmatched on each side, and the difference they leave",
         context do
      %{operator: operator, bank_account: bank_account} = context

      assert {:ok, figures} =
               Reconciliation.preview_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-10-31],
                 statement_balance: "949.50"
               })

      assert decimal?(figures.statement_balance, "949.50")
      # 1000 - 45.50 - 120 + 300
      assert decimal?(figures.book_balance, "1134.50")
      assert figures.through_entry_number == 4
      assert figures.through_statement_number == 1
      assert figures.through_match_event_number == 2
      assert figures.currency_code == "XTS"

      assert [
               %{kind: "statement_line", description: "Monthly fee", amount: fee},
               %{kind: "entry", description: "Entry 3: Entry on 2026-10-30", amount: cheque},
               %{kind: "entry", description: "Entry 4: Entry on 2026-10-31", amount: in_transit}
             ] = figures.items

      assert decimal?(fee, -5) and decimal?(cheque, -120) and decimal?(in_transit, 300)
      # 949.50 - 1134.50 - (-5) + (-120 + 300) = 0
      assert decimal?(figures.difference, 0)

      assert {:ok, wrong} =
               Reconciliation.preview_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-10-31],
                 statement_balance: "950.00"
               })

      assert decimal?(wrong.difference, "0.50")

      assert {:error, :invalid_option} =
               Reconciliation.preview_reconciliation(operator, 73, bank_account.id, %{
                 end_date: "2026-10-31",
                 statement_balance: "1"
               })
    end

    test "count a match cleared after the end date as a timing item", context do
      %{operator: operator, bank_account: bank_account, cheque: cheque} = context

      november =
        import!(context, [["2026-11-02", "Cheque", "", "-120.00", "829.50"]], "november.csv")

      context.match!.(hd(november.lines), cheque)

      assert {:ok, figures} =
               Reconciliation.preview_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-10-31],
                 statement_balance: "949.50"
               })

      assert [
               %{kind: "statement_line"},
               %{kind: "entry", amount: in_transit},
               %{kind: "timing", match_id: _, item_date: ~D[2026-10-30], amount: timing}
             ] = figures.items

      assert decimal?(in_transit, 300) and decimal?(timing, -120)
      assert decimal?(figures.difference, 0)
    end
  end

  describe "a reconciliation" do
    test "is opened, finalised only at zero difference, and then kept with its snapshot",
         context do
      %{
        operator: operator,
        bank_account: bank_account,
        fee_line: fee_line,
        in_transit: in_transit
      } = context

      assert {:ok, opened} =
               Reconciliation.open_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-10-31],
                 statement_balance: "949.50"
               })

      assert opened.reconciliation_number == 1
      assert opened.status == "open"
      assert [%{event_number: 1, action: "opened", recorded_by_user_id: 91}] = opened.events

      assert {:error, changeset} =
               Reconciliation.open_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-11-30],
                 statement_balance: "1"
               })

      assert %{bank_account_id: ["already has an open reconciliation"]} = errors_on(changeset)

      assert {:ok, %{status: "open", items: [_, _, _], difference: difference}} =
               Reconciliation.get_reconciliation(operator, 73, opened.id)

      assert decimal?(difference, 0)

      assert {:ok, finalised} = Reconciliation.finalise_reconciliation(operator, 73, opened.id)
      assert finalised.status == "finalised"

      assert [
               _opened,
               %{
                 action: "finalised",
                 book_balance: book,
                 difference: zero,
                 through_entry_number: 4,
                 through_statement_number: 1,
                 through_match_event_number: 2
               }
             ] =
               finalised.events

      assert decimal?(book, "1134.50") and decimal?(zero, 0)

      assert {:ok, report} = Reconciliation.get_reconciliation(operator, 73, opened.id)
      assert report.through_entry_number == 4
      assert Enum.map(report.items, & &1.kind) == ~w(statement_line entry entry)
      assert Enum.find(report.items, &(&1.statement_line_id == fee_line.id))

      # The snapshot reproduces from its numbers, however much happens later.
      bank_entry!(context, ~D[2026-10-02], "999")
      import!(context, [["2026-10-25", "Late import", "", "33.00", "982.50"]], "late.csv")

      assert {:ok, again} =
               Reconciliation.preview_reconciliation(
                 operator,
                 73,
                 bank_account.id,
                 %{end_date: ~D[2026-10-31], statement_balance: "949.50"},
                 through_entry_number: 4,
                 through_statement_number: 1,
                 through_match_event_number: 2
               )

      assert again.items == report.items
      assert decimal?(again.book_balance, "1134.50")

      assert {:ok, %{items: items}} = Reconciliation.get_reconciliation(operator, 73, opened.id)
      assert items == report.items

      assert {:error, :reconciliation_finalised} =
               Reconciliation.finalise_reconciliation(operator, 73, opened.id)

      assert {:error, :reconciliation_finalised} =
               Reconciliation.abandon_reconciliation(operator, 73, opened.id, %{reason: "No"})

      # The next reconciliation must end after this one, and the in-transit
      # deposit it listed is matched in November like any other.
      assert {:error, changeset} =
               Reconciliation.open_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-10-31],
                 statement_balance: "1"
               })

      assert %{end_date: ["must be after the last finalised reconciliation, 2026-10-31"]} =
               errors_on(changeset)

      november =
        import!(context, [["2026-11-01", "Deposit", "", "300.00", "1282.50"]], "november.csv")

      assert %{status: "matched"} = context.match!.(hd(november.lines), in_transit)
    end

    test "keeps a match a finalised reconciliation counted", context do
      %{operator: operator, bank_account: bank_account, fee_line: fee_line} = context

      {:ok, posted} =
        Reconciliation.post_statement_line(operator, 73, fee_line.id, %{kind: "charge"})

      {:ok, opened} =
        Reconciliation.open_reconciliation(operator, 73, bank_account.id, %{
          end_date: ~D[2026-10-31],
          statement_balance: "949.50"
        })

      assert {:ok, _} = Reconciliation.finalise_reconciliation(operator, 73, opened.id)

      assert {:error, :match_finalised} =
               Reconciliation.unmatch(operator, 73, posted.match.id, %{reason: "Try"})

      # The owner's reversal unmatches first, so it keeps the entry too.
      assert {:error, :match_finalised} =
               Reconciliation.reverse_statement_line(operator, 73, fee_line.id, %{reason: "Try"})

      assert {:ok, %{reversed_by_entry_id: nil}} =
               Ledger.get_entry(operator, 73, posted.entry.id)

      assert_raise Postgrex.Error,
                   ~r/was counted by a finalised reconciliation and is kept/,
                   fn ->
                     SQL.query!(
                       Repo,
                       "INSERT INTO finance_reconciliation_match_events (tenant_id, company_id, match_id, action, reason, recorded_by_user_id) VALUES (41, 73, $1, 'unmatched', 'Force', 1)",
                       [posted.match.id]
                     )
                   end

      # A match made after the finalisation is still undone.
      {:ok, late_match} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [
            hd(
              import!(context, [["2026-11-02", "Cheque", "", "-120.00", "829.50"]], "n.csv").lines
            ).id
          ],
          entry_ids: [context.cheque.id]
        })

      assert {:ok, %{status: "unmatched"}} =
               Reconciliation.unmatch(operator, 73, late_match.id, %{reason: "Wrong cheque"})
    end

    test "is abandoned with a reason and then a new one opens", context do
      %{operator: operator, bank_account: bank_account} = context

      {:ok, opened} =
        Reconciliation.open_reconciliation(operator, 73, bank_account.id, %{
          end_date: ~D[2026-10-31],
          statement_balance: "1.00"
        })

      # The statement shows 949.50 on the 31st; a balance of 1.00 is 948.50
      # off, and nothing unmatched explains it.
      assert {:error, {:difference, off}} =
               Reconciliation.finalise_reconciliation(operator, 73, opened.id)

      assert decimal?(off, "-948.50")

      assert {:error, changeset} =
               Reconciliation.abandon_reconciliation(operator, 73, opened.id, %{})

      assert %{reason: ["is needed to abandon a reconciliation"]} = errors_on(changeset)

      assert {:ok, abandoned} =
               Reconciliation.abandon_reconciliation(operator, 73, opened.id, %{
                 reason: "Typed the wrong balance"
               })

      assert abandoned.status == "abandoned"

      assert {:ok, %{status: "abandoned"} = report} =
               Reconciliation.get_reconciliation(operator, 73, opened.id)

      refute Map.has_key?(report, :items)

      assert {:ok, %{reconciliation_number: 2}} =
               Reconciliation.open_reconciliation(operator, 73, bank_account.id, %{
                 end_date: ~D[2026-10-31],
                 statement_balance: "949.50"
               })

      assert {:ok, [%{status: "abandoned"}, %{status: "open"}]} =
               Reconciliation.list_reconciliations(operator, 73, bank_account.id)

      assert_raise Postgrex.Error, ~r/already has an open reconciliation/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_reconciliation_reconciliations (tenant_id, company_id, bank_account_id, end_date, statement_balance, opened_by_user_id) VALUES (41, 73, $1, '2026-12-31', 1, 1)",
          [bank_account.id]
        )
      end
    end

    test "needs the reconciliation capabilities", context do
      %{first_scope: first, operator: operator, bank_account: bank_account} = context

      opener =
        TestFixtures.sign_in!(first, 73, 92, [
          "finance.reconciliation.view",
          "finance.reconciliation.reconciliations.manage",
          "finance.ledger.view"
        ])

      {:ok, opened} =
        Reconciliation.open_reconciliation(opener, 73, bank_account.id, %{
          end_date: ~D[2026-10-31],
          statement_balance: "949.50"
        })

      assert {:error, :unauthorized} =
               Reconciliation.finalise_reconciliation(opener, 73, opened.id)

      assert {:error, :reconciliation_not_found} =
               Reconciliation.finalise_reconciliation(operator, 73, 999)

      assert {:ok, _} = Reconciliation.finalise_reconciliation(operator, 73, opened.id)
    end
  end
end
