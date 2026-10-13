defmodule Bilimbi.Finance.Reconciliation.ImportTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Reconciliation.Records
  alias Ecto.Adapters.SQL

  @rows [
    ["2026-10-01", "Opening deposit", "DEP-1", "1000.00", "1000.00"],
    ["2026-10-03", "Card payment", "POS-77", "-45.50", "954.50"],
    ["2026-10-03", "Card payment", "POS-77", "-45.50", "909.00"],
    ["2026-10-05", "Bank charge", "", "-5.00", "904.00"]
  ]

  describe "importing a statement" do
    test "numbers the statement, keeps its lines in order, and derives its balances", context do
      statement = import!(context, @rows)

      assert statement.statement_number == 1
      assert statement.file_name == "statement.csv"
      assert statement.file_sha256 =~ ~r/^[0-9a-f]{64}$/
      assert statement.line_count == 4
      assert statement.skipped_count == 0
      assert statement.start_date == ~D[2026-10-01]
      assert statement.end_date == ~D[2026-10-05]
      assert decimal?(statement.opening_balance, 0)
      assert decimal?(statement.closing_balance, "904.00")
      assert statement.imported_by_user_id == 91
      assert %DateTime{} = statement.imported_at

      assert [
               %{
                 line_number: 1,
                 line_date: ~D[2026-10-01],
                 description: "Opening deposit",
                 reference: "DEP-1"
               },
               %{line_number: 2, reference: "POS-77"},
               %{line_number: 3, reference: "POS-77"},
               %{line_number: 4, description: "Bank charge", reference: nil}
             ] = statement.lines

      assert decimal?(Enum.at(statement.lines, 1).amount, "-45.50")
      assert decimal?(Enum.at(statement.lines, 3).running_balance, "904.00")

      assert {:ok, [listed]} =
               Reconciliation.list_statements(context.operator, 73, context.bank_account.id)

      assert listed.statement_number == 1 and listed.lines == []

      assert {:ok, %{lines: [_, _, _, _]}} =
               Reconciliation.get_statement(context.operator, 73, statement.id)
    end

    test "walks every page of statements, so the newest is listed", context do
      import!(context, @rows)
      next = import!(context, [["2026-10-06", "Interest", "INT", "1.25", "905.25"]], "next.csv")

      read = &Reconciliation.list_statements(context.operator, 73, context.bank_account.id, &1)

      assert {:ok, [%{statement_number: 1}]} = read.(limit: 1)
      assert {:ok, all} = Records.all_pages(read, 1)
      assert Enum.map(all, & &1.statement_number) == [1, 2]
      assert List.last(all).id == next.id
    end

    test "reads a file written newest first by following its running balance", context do
      statement = import!(context, Enum.reverse(@rows))

      assert Enum.map(statement.lines, & &1.line_date) ==
               [~D[2026-10-01], ~D[2026-10-03], ~D[2026-10-03], ~D[2026-10-05]]

      assert decimal?(statement.closing_balance, "904.00")
    end

    test "refuses a running balance that does not follow from the amounts", context do
      rows = List.replace_at(@rows, 3, ["2026-10-05", "Bank charge", "", "-5.00", "900.00"])

      assert {:error, {:running_balance_mismatch, 5}} =
               Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
                 file_name: "statement.csv",
                 content: TestFixtures.csv(rows)
               })
    end

    test "refuses the same file and the same line a second time, whole", context do
      %{operator: operator, bank_account: bank_account} = context
      import!(context, @rows)

      assert {:error, {:duplicate_file, 1}} =
               Reconciliation.import_statement(operator, 73, bank_account.id, %{
                 file_name: "again.csv",
                 content: TestFixtures.csv(@rows)
               })

      # An overlapping export: one line is new, three are already imported.
      overlap = [
        ["2026-10-03", "Card payment", "POS-77", "-45.50", "954.50"],
        ["2026-10-03", "Card payment", "POS-77", "-45.50", "909.00"],
        ["2026-10-05", "Bank charge", "", "-5.00", "904.00"],
        ["2026-10-06", "Interest", "INT", "1.25", "905.25"]
      ]

      assert {:error, {:duplicate_lines, duplicates}} =
               Reconciliation.import_statement(operator, 73, bank_account.id, %{
                 file_name: "overlap.csv",
                 content: TestFixtures.csv(overlap)
               })

      assert [
               %{row: 2, line_number: 1, statement_number: 1, statement_line_number: 2},
               %{row: 3, line_number: 2, statement_number: 1, statement_line_number: 3},
               %{row: 4, line_number: 3, statement_number: 1, statement_line_number: 4}
             ] = duplicates

      assert {:ok, [_only_the_first]} =
               Reconciliation.list_statements(operator, 73, bank_account.id)

      # The next statement carries on where the first ended.
      next = import!(context, [["2026-10-06", "Interest", "INT", "1.25", "905.25"]], "next.csv")
      assert next.statement_number == 2
      assert decimal?(next.opening_balance, "904.00")
    end

    test "reads debit and credit columns by position, skips zero rows, and reads other date and amount forms",
         context do
      %{operator: operator, accounts: accounts} = context

      {:ok, account} =
        Reconciliation.create_bank_account(operator, 73, %{
          name: "Second account",
          ledger_account_id: accounts.other_bank.id,
          import_mapping: %{
            "header_rows" => 2,
            "delimiter" => ";",
            "date" => 1,
            "date_format" => "DD/MM/YYYY",
            "description" => 2,
            "debit" => 3,
            "credit" => 4,
            "decimal_separator" => ","
          }
        })

      content =
        TestFixtures.csv(
          [
            ["Account statement", "", "", ""],
            ["Date", "Details", "Debit", "Credit"],
            ["02/10/2026", "Salary run", "1.234,50", ""],
            ["03/10/2026", "Rounding", "0,00", ""],
            ["04/10/2026", "Customer receipt", "", "2.000,00"],
            ["05/10/2026", "Fee", "(12,00)", ""]
          ],
          header: false,
          delimiter: ";"
        )

      assert {:ok, statement} =
               Reconciliation.import_statement(operator, 73, account.id, %{
                 file_name: "second.csv",
                 content: content
               })

      assert statement.line_count == 3
      assert statement.skipped_count == 1
      assert statement.opening_balance == nil

      assert [
               %{line_date: ~D[2026-10-02], amount: salary},
               %{line_date: ~D[2026-10-04], amount: receipt},
               %{line_date: ~D[2026-10-05], amount: fee}
             ] = statement.lines

      assert decimal?(salary, "-1234.50")
      assert decimal?(receipt, "2000.00")
      assert decimal?(fee, "-12.00")
    end

    test "names every row the mapping cannot read", context do
      rows = [
        ["2026-10-01", "Fine", "", "10.00", "10.00"],
        ["01-10-2026", "", "", "abc", "x"],
        ["2026-10-02", "Too fine", "", "1.005", "11.005"]
      ]

      assert {:error, {:invalid_lines, errors}} =
               Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
                 file_name: "bad.csv",
                 content: TestFixtures.csv(rows)
               })

      assert [%{row: 3, message: date_message}, %{row: 4, message: precision_message}] = errors
      assert date_message =~ "is not YYYY-MM-DD"
      assert precision_message =~ "more decimal places"

      assert {:error, {:missing_headers, ["Balance"]}} =
               Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
                 file_name: "headers.csv",
                 content: "Date,Description,Reference,Amount\n2026-10-01,A,,1\n"
               })

      assert {:error, :no_lines} =
               Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
                 file_name: "empty.csv",
                 content: "Date,Description,Reference,Amount,Balance\n"
               })

      assert {:error, {:unterminated_quote, 2}} =
               Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
                 file_name: "quote.csv",
                 content: "Date,Description,Reference,Amount,Balance\n2026-10-01,\"Open,,1,1\n"
               })
    end

    test "needs the import capability, an active bank account, and an open book", context do
      %{first_scope: first, operator: operator, bank_account: bank_account} = context

      viewer =
        TestFixtures.sign_in!(first, 73, 92, [
          "finance.reconciliation.view",
          "finance.ledger.view"
        ])

      assert {:error, :unauthorized} =
               Reconciliation.import_statement(viewer, 73, bank_account.id, %{
                 file_name: "s.csv",
                 content: TestFixtures.csv(@rows)
               })

      {:ok, _} =
        Reconciliation.update_bank_account(operator, 73, bank_account.id, %{active: false})

      assert {:error, :bank_account_inactive} =
               Reconciliation.import_statement(operator, 73, bank_account.id, %{
                 file_name: "s.csv",
                 content: TestFixtures.csv(@rows)
               })

      assert {:error, :bank_account_not_found} =
               Reconciliation.import_statement(operator, 73, 999, %{
                 file_name: "s.csv",
                 content: ""
               })
    end
  end

  describe "the database" do
    test "keeps statements and lines, and refuses a line added later", context do
      statement = import!(context, @rows)

      for sql <- [
            "UPDATE finance_reconciliation_statements SET file_name = 'x'",
            "DELETE FROM finance_reconciliation_statements",
            "UPDATE finance_reconciliation_statement_lines SET amount = 1",
            "DELETE FROM finance_reconciliation_statement_lines"
          ] do
        assert_raise Postgrex.Error, ~r/finance reconciliation keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end

      # The sandbox is one transaction, so the "earlier transaction" rule is
      # proved by the contract test; here the count rule catches a stray line.
      SQL.query!(
        Repo,
        "INSERT INTO finance_reconciliation_statement_lines (tenant_id, company_id, statement_id, bank_account_id, line_number, line_date, description, amount, fingerprint) VALUES (41, 73, $1, $2, 9, '2026-10-04', 'Stray', 1, repeat('a', 64))",
        [statement.id, context.bank_account.id]
      )

      assert_raise Postgrex.Error, ~r/counts 4 lines but holds a different number/, fn ->
        TestFixtures.check_deferred_constraints!()
      end
    end
  end
end
