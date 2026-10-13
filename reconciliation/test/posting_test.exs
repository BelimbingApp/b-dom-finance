defmodule Bilimbi.Finance.Reconciliation.PostingTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  setup context do
    statement =
      import!(context, [
        ["2026-10-20", "Monthly fee", "FEE", "-5.00", "995.00"],
        ["2026-10-31", "Credit interest", "", "1.25", "996.25"]
      ])

    [fee, interest] = statement.lines
    Map.merge(context, %{fee: fee, interest: interest})
  end

  test "posts a charge and interest through the ledger and matches each line to its entry",
       context do
    %{
      operator: operator,
      accounts: accounts,
      fee: fee,
      interest: interest,
      bank_account: bank_account
    } = context

    assert {:ok, %{entry: entry, match: match}} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

    assert entry.entry_date == ~D[2026-10-20]
    assert entry.description == "Monthly fee"
    assert entry.reference == "FEE"

    assert [
             %{account_id: charges, debit: debit},
             %{account_id: bank, credit: credit}
           ] = entry.lines

    assert charges == accounts.charges.id and bank == accounts.bank.id
    assert decimal?(debit, 5) and decimal?(credit, 5)

    assert match.statement_line_ids == [fee.id]
    assert [%{entry_id: entry_id, amount: amount}] = match.entries
    assert entry_id == entry.id and decimal?(amount, -5)
    assert match.note == "Posted from statement line as charge"

    assert {:ok, %{entry: interest_entry}} =
             Reconciliation.post_statement_line(operator, 73, interest.id, %{
               kind: "interest",
               description: "October interest"
             })

    assert interest_entry.description == "October interest"
    assert [%{account_id: bank2, debit: in_debit}, %{account_id: income}] = interest_entry.lines
    assert bank2 == accounts.bank.id and income == accounts.interest.id
    assert decimal?(in_debit, "1.25")

    assert {:ok, %{lines: [], entries: []}} =
             Reconciliation.unmatched_items(operator, 73, bank_account.id)

    assert {:error, :statement_line_matched} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

    # The entry is the line's own: the ledger refuses a direct reversal of it,
    # and once the line is unmatched it is matched to that entry again, never
    # posted twice.
    assert {:ok, %{owner: %{module: "finance/reconciliation", record: record}}} =
             Ledger.get_entry(operator, 73, entry.id)

    assert record == "statement_line:#{fee.id}"

    assert {:error, {:owned_by, %{module: "finance/reconciliation"}}} =
             Ledger.reverse_entry(operator, 73, entry.id, %{
               entry_date: ~D[2026-10-21],
               description: "Undo"
             })

    assert {:ok, %{status: "unmatched"}} =
             Reconciliation.unmatch(operator, 73, match.id, %{reason: "Wrong kind"})

    assert {:error, :statement_line_posted} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

    assert {:ok, %{status: "matched"}} =
             Reconciliation.match(operator, 73, bank_account.id, %{
               statement_line_ids: [fee.id],
               entry_ids: [entry.id]
             })
  end

  test "refuses the wrong kind, a missing counter account, and a closed period, recording nothing",
       context do
    %{operator: operator, fee: fee, interest: interest, bank_account: bank_account} = context

    assert {:error, :not_a_charge} =
             Reconciliation.post_statement_line(operator, 73, interest.id, %{kind: "charge"})

    assert {:error, :not_interest} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "interest"})

    assert {:error, :invalid_kind} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "refund"})

    assert {:error, :statement_line_not_found} =
             Reconciliation.post_statement_line(operator, 73, 999, %{kind: "charge"})

    {:ok, _} =
      Reconciliation.update_bank_account(operator, 73, bank_account.id, %{charges_account_id: nil})

    assert {:error, :no_charges_account} =
             Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

    # A closed period: the ledger refuses and its changeset comes back, with
    # neither an entry nor a match recorded.
    {:ok, years} = Ledger.list_fiscal_years(operator, 73)
    [year] = Enum.filter(years, &(&1.start_date == ~D[2026-01-01]))
    [first | _] = year.periods

    for period <- Enum.take(year.periods, 10) do
      {:ok, _} = Ledger.close_period(operator, 73, period.id, %{})
    end

    assert first.start_date == ~D[2026-01-01]

    assert {:error, changeset} =
             Reconciliation.post_statement_line(operator, 73, interest.id, %{kind: "interest"})

    assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)

    assert {:ok, %{lines: [_, _]}} = Reconciliation.unmatched_items(operator, 73, bank_account.id)
    assert {:ok, []} = Reconciliation.list_matches(operator, 73, bank_account.id)
  end

  test "needs the posting capabilities of both modules", context do
    %{first_scope: first, fee: fee} = context

    without_ledger =
      TestFixtures.sign_in!(first, 73, 92, [
        "finance.reconciliation.view",
        "finance.reconciliation.statement-lines.post",
        "finance.ledger.view"
      ])

    assert {:error, :unauthorized} =
             Reconciliation.post_statement_line(without_ledger, 73, fee.id, %{kind: "charge"})

    without_module =
      TestFixtures.sign_in!(first, 73, 93, [
        "finance.reconciliation.view",
        "finance.ledger.entries.post"
      ])

    assert {:error, :unauthorized} =
             Reconciliation.post_statement_line(without_module, 73, fee.id, %{kind: "charge"})
  end

  describe "reversing the entry a line posted" do
    test "unmatches the line and reverses the entry as its owner, in one step", context do
      %{operator: operator, fee: fee, bank_account: bank_account} = context

      {:ok, %{entry: entry, match: match}} =
        Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

      assert {:error, :invalid_reason} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{reason: "  "})

      assert {:error, :invalid_reason} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{})

      assert {:ok, %{reversal: reversal, match: unmatched}} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{
                 reason: "Charged in error",
                 entry_date: ~D[2026-10-22]
               })

      assert reversal.entry_date == ~D[2026-10-22]
      assert reversal.reverses_entry_id == entry.id

      assert reversal.owner == %{
               module: "finance/reconciliation",
               record: "statement_line:#{fee.id}"
             }

      assert {:ok, %{reversed_by_entry_id: reversal_id}} =
               Ledger.get_entry(operator, 73, entry.id)

      assert reversal_id == reversal.id

      assert unmatched.id == match.id and unmatched.status == "unmatched"

      assert [%{action: "matched"}, %{action: "unmatched", reason: "Charged in error"} = event] =
               unmatched.events

      assert event.recorded_by_user_id == 91

      assert {:ok, %{lines: [%{id: line_id}, _interest]}} =
               Reconciliation.unmatched_items(operator, 73, bank_account.id)

      assert line_id == fee.id

      # The line's own entry stays the line's: it is not posted again, and
      # nothing is left to reverse a second time.
      assert {:error, :statement_line_posted} =
               Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

      assert {:error, :statement_line_not_matched} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{reason: "Again"})
    end

    test "refuses a line whose match is not its own posting, recording nothing", context do
      %{operator: operator, fee: fee, bank_account: bank_account} = context

      assert {:error, :statement_line_not_matched} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{reason: "Unposted"})

      assert {:error, :statement_line_not_found} =
               Reconciliation.reverse_statement_line(operator, 73, 999, %{reason: "Missing"})

      manual =
        bank_entry!(context, ~D[2026-10-20], "-5.00")

      {:ok, match} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [fee.id],
          entry_ids: [manual.id]
        })

      assert {:error, :statement_line_not_posted} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{reason: "Manual"})

      assert {:ok, %{status: "matched"}} = Reconciliation.get_match(operator, 73, match.id)
      assert {:ok, %{reversed_by_entry_id: nil}} = Ledger.get_entry(operator, 73, manual.id)
    end

    test "reverses an unclaimed entry posted before owners were recorded, only when the match posted it",
         context do
      %{operator: operator, accounts: accounts, bank_account: bank_account} = context
      %{fee: fee, interest: interest} = context

      legacy = fn id, description, debit_account, credit_account, amount ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, posted_by_user_id, posted_at, legacy) VALUES ($1, 41, 73, $1, '2026-10-20', $2, 'XTS', 91, now(), true)",
          [id, description]
        )

        SQL.query!(
          Repo,
          "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (41, 73, $1, 1, $2, $4, 0), (41, 73, $1, 2, $3, 0, $4)",
          [id, debit_account.id, credit_account.id, Decimal.new(amount)]
        )

        id
      end

      posted = legacy.(9001, "Monthly fee", accounts.charges, accounts.bank, "5.00")
      by_hand = legacy.(9002, "Interest", accounts.bank, accounts.interest, "1.25")

      {:ok, _} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [fee.id],
          entry_ids: [posted],
          note: "Posted from statement line as charge"
        })

      {:ok, _} =
        Reconciliation.match(operator, 73, bank_account.id, %{
          statement_line_ids: [interest.id],
          entry_ids: [by_hand]
        })

      assert {:error, :statement_line_not_posted} =
               Reconciliation.reverse_statement_line(operator, 73, interest.id, %{reason: "No"})

      assert {:ok, %{reversal: reversal, match: %{status: "unmatched"}}} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{
                 reason: "Charged in error",
                 entry_date: ~D[2026-10-22]
               })

      assert reversal.reverses_entry_id == posted and reversal.owner == nil

      assert {:ok, %{reversed_by_entry_id: reversal_id}} = Ledger.get_entry(operator, 73, posted)
      assert reversal_id == reversal.id
      assert {:ok, %{reversed_by_entry_id: nil}} = Ledger.get_entry(operator, 73, by_hand)
    end

    test "rolls the unmatch back when the ledger refuses the reversal", context do
      %{operator: operator, fee: fee} = context

      {:ok, %{entry: entry, match: match}} =
        Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

      {:ok, years} = Ledger.list_fiscal_years(operator, 73)
      [year] = Enum.filter(years, &(&1.start_date == ~D[2026-01-01]))

      for period <- Enum.take(year.periods, 10) do
        {:ok, _} = Ledger.close_period(operator, 73, period.id, %{})
      end

      assert {:error, changeset} =
               Reconciliation.reverse_statement_line(operator, 73, fee.id, %{
                 reason: "Charged in error",
                 entry_date: ~D[2026-10-22]
               })

      assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)
      assert {:ok, %{status: "matched"}} = Reconciliation.get_match(operator, 73, match.id)
      assert {:ok, %{reversed_by_entry_id: nil}} = Ledger.get_entry(operator, 73, entry.id)
    end

    test "needs the reversing capability and the ledger's posting grant", context do
      %{first_scope: first, operator: operator, fee: fee} = context

      {:ok, _posted} =
        Reconciliation.post_statement_line(operator, 73, fee.id, %{kind: "charge"})

      without_module =
        TestFixtures.sign_in!(first, 73, 92, [
          "finance.reconciliation.view",
          "finance.reconciliation.statement-lines.post",
          "finance.ledger.entries.post",
          "finance.ledger.view"
        ])

      assert {:error, :unauthorized} =
               Reconciliation.reverse_statement_line(without_module, 73, fee.id, %{reason: "No"})

      without_ledger =
        TestFixtures.sign_in!(first, 73, 93, [
          "finance.reconciliation.view",
          "finance.reconciliation.statement-lines.manage",
          "finance.ledger.view"
        ])

      assert {:error, :unauthorized} =
               Reconciliation.reverse_statement_line(without_ledger, 73, fee.id, %{reason: "No"})
    end
  end
end
