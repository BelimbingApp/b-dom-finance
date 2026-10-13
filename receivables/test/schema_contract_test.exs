defmodule Bilimbi.Finance.Receivables.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Receivables.SchemaContract
  alias Bilimbi.Finance.Receivables.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup context do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_receivables_#{String.replace(Ecto.UUID.generate(), "-", "")}"
    quoted = SchemaVerifier.quote_identifier!(database)
    Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "CREATE DATABASE #{quoted}", []) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "DROP DATABASE #{quoted}", []) end)
    end)

    repo = Module.concat(__MODULE__, FreshRepo)

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 2},
        id: repo
      )
    )

    migrate! = fn migrations ->
      for {version, module} <- migrations do
        assert :ok = Ecto.Migrator.up(Repo, version, module, log: false, dynamic_repo: repo)
      end
    end

    # The ledger's migrations come first, as in a composed database: the
    # claim migration calls the ledger's claim function.
    [create, claim] = TestFixtures.migrations()
    {ledger, [owner]} = Enum.split(LedgerFixtures.migrations(), 3)
    migrate!.(ledger ++ [create])
    # One test posts before the ledger recorded owners and migrates itself.
    unless context[:before_claim], do: migrate!.([owner, claim])

    %{repo: repo, migrate_claim!: fn -> migrate!.([owner, claim]) end}
  end

  test "the fresh migration implements the complete receivables contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred payment check runs at commit. A refused commit
  # disconnects, which Postgrex logs; the log is expected.
  @tag :capture_log
  test "the migration's triggers keep documents and payments numbered, settled, and kept",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_receivables_series (id, tenant_id, company_id, code, name, kind, prefix, number_width, inserted_at, updated_at) VALUES (1, 1, 1, 'I', 'Invoices', 'invoice', 'I-', 3, now(), now()), (2, 1, 1, 'C', 'Credits', 'credit_note', 'C-', 3, now(), now()), (3, 1, 1, 'P', 'Payments', 'payment', 'P-', 3, now(), now())",
        "INSERT INTO finance_receivables_customers (id, tenant_id, company_id, code, name, inserted_at, updated_at) VALUES (1, 1, 1, 'C1', 'Customer', now(), now())",
        "INSERT INTO finance_receivables_tax_codes (id, tenant_id, company_id, code, name, rate, account_id, inserted_at, updated_at) VALUES (1, 1, 1, 'T', 'Tax', 10, 9, now(), now())"
      ])

    draft = fn id, kind, series, credited ->
      "INSERT INTO finance_receivables_documents (id, tenant_id, company_id, kind, status, series_id, customer_id, credited_document_id, currency_code, issue_date, subtotal, tax_total, total, inserted_at, updated_at) VALUES (#{id}, 1, 1, '#{kind}', 'draft', #{series}, 1, #{credited}, 'XTS', '2026-10-01', 100, 10, 110, now(), now())"
    end

    line = fn document_id ->
      "INSERT INTO finance_receivables_document_lines (tenant_id, company_id, document_id, line_number, description, quantity, unit_price, amount, account_id, tax_code_id, tax_rate, tax_amount) VALUES (1, 1, #{document_id}, 1, 'Work', 1, 100, 100, 8, 1, 10, 10)"
    end

    tax_line = fn document_id ->
      "INSERT INTO finance_receivables_document_tax_lines (tenant_id, company_id, document_id, tax_code_id, tax_code, tax_rate, taxable_amount, tax_amount, account_id) VALUES (1, 1, #{document_id}, 1, 'T', 10, 100, 10, 9)"
    end

    issue_to = fn id, number, account ->
      "UPDATE finance_receivables_documents SET status = 'issued', document_number = #{number}, document_reference = 'R-#{id}', due_date = '2026-10-31', party_name = 'Customer', receivable_account_id = #{account}, ledger_entry_id = #{id}, ledger_entry_number = #{id}, issued_by_user_id = 1, issued_at = '2000-01-01' WHERE id = #{id}"
    end

    issue = &issue_to.(&1, &2, 5)

    assert {:ok, _} = in_transaction.([draft.(1, "invoice", 1, "NULL"), line.(1), tax_line.(1)])

    # An issued document records the receivable account it posted to.
    assert_raise Postgrex.Error, ~r/finance_receivables_documents_issued/, fn ->
      in_transaction.([issue_to.(1, 1, "NULL")])
    end

    # A number other than the series' next is refused, and so are totals
    # that do not equal the lines.
    assert_raise Postgrex.Error, ~r/not the next number/, fn ->
      in_transaction.([issue.(1, 2)])
    end

    assert {:ok, _} = in_transaction.([draft.(2, "invoice", 1, "NULL"), line.(2)])

    assert_raise Postgrex.Error, ~r/totals do not equal its lines/, fn ->
      in_transaction.([issue.(2, 1)])
    end

    assert {:ok, _} = in_transaction.([issue.(1, 1)])

    # An issued document, its lines, and its tax lines are kept as issued.
    for sql <- [
          "UPDATE finance_receivables_documents SET description = 'x' WHERE id = 1",
          "UPDATE finance_receivables_documents SET status = 'draft' WHERE id = 1"
        ] do
      assert_raise Postgrex.Error, ~r/is issued: it is never changed/, fn -> query!.(sql) end
    end

    for sql <- [
          "DELETE FROM finance_receivables_document_lines WHERE document_id = 1",
          "UPDATE finance_receivables_document_tax_lines SET tax_amount = 0 WHERE document_id = 1",
          line.(1)
        ] do
      assert_raise Postgrex.Error, ~r/no longer a draft/, fn -> query!.(sql) end
    end

    assert_raise Postgrex.Error, ~r/created as a draft/, fn ->
      query!.(String.replace(draft.(9, "invoice", 1, "NULL"), "'draft'", "'issued'"))
    end

    # A credit note credits no more than the invoice owes.
    assert {:ok, _} =
             in_transaction.([
               draft.(3, "credit_note", 2, 1),
               line.(3),
               tax_line.(3)
             ])

    # ... and posts to the receivable account its invoice recorded.
    assert_raise Postgrex.Error, ~r/receivable account of its invoice/, fn ->
      in_transaction.([issue_to.(3, 1, 6)])
    end

    assert {:ok, _} = in_transaction.([issue.(3, 1)])
    assert %{rows: [[zero]]} = query!.("SELECT finance_receivables_outstanding(1)")
    assert Decimal.equal?(zero, 0)

    # Payments: numbered next in a payment series, allocated whole, and
    # never beyond what an invoice owes, checked at commit.
    assert {:ok, _} = in_transaction.([draft.(4, "invoice", 1, "NULL"), line.(4), tax_line.(4)])
    assert {:ok, _} = in_transaction.([issue.(4, 2)])

    payment = fn id, number, amount ->
      "INSERT INTO finance_receivables_payments (id, tenant_id, company_id, series_id, customer_id, payment_number, payment_reference, payment_date, amount, currency_code, deposit_account_id, ledger_entry_id, ledger_entry_number, recorded_by_user_id, recorded_at) VALUES (#{id}, 1, 1, 3, 1, #{number}, 'P-#{id}', '2026-10-02', #{amount}, 'XTS', 7, #{id}, #{id}, 1, '2000-01-01')"
    end

    allocation = fn payment_id, document_id, amount ->
      "INSERT INTO finance_receivables_allocations (tenant_id, company_id, payment_id, document_id, amount) VALUES (1, 1, #{payment_id}, #{document_id}, #{amount})"
    end

    assert_raise Postgrex.Error, ~r/allocations do not equal its amount/, fn ->
      in_transaction.([payment.(1, 1, 50), allocation.(1, 4, 40)])
    end

    assert_raise Postgrex.Error, ~r/beyond what it owes/, fn ->
      in_transaction.([payment.(1, 1, 200), allocation.(1, 4, 200)])
    end

    assert_raise Postgrex.Error, ~r/issued invoice of its customer/, fn ->
      in_transaction.([payment.(1, 1, 10), allocation.(1, 3, 10)])
    end

    assert_raise Postgrex.Error, ~r/not the next number/, fn ->
      in_transaction.([payment.(1, 2, 50), allocation.(1, 4, 50)])
    end

    assert {:ok, _} = in_transaction.([payment.(1, 1, 50), allocation.(1, 4, 50)])

    # Payments, allocations, and reversals are append-only, and nothing is
    # deleted or truncated.
    for sql <- [
          "UPDATE finance_receivables_payments SET amount = 1",
          "DELETE FROM finance_receivables_allocations",
          "DELETE FROM finance_receivables_documents WHERE id = 2",
          "DELETE FROM finance_receivables_customers",
          "TRUNCATE finance_receivables_series CASCADE"
        ] do
      assert_raise Postgrex.Error, ~r/finance receivables keeps/, fn -> query!.(sql) end
    end

    for sql <- [
          "UPDATE finance_receivables_tax_codes SET rate = 5",
          "UPDATE finance_receivables_series SET prefix = 'X-'",
          "UPDATE finance_receivables_customers SET code = 'C2'"
        ] do
      assert_raise Postgrex.Error, ~r/finance receivables keeps \w+ of/, fn -> query!.(sql) end
    end

    # The setup's change log is append-only, and the database stamps when.
    assert {:ok, _} =
             in_transaction.([
               "INSERT INTO finance_receivables_setup_changes (tenant_id, company_id, field, old_value, new_value, changed_by_user_id, changed_at) VALUES (1, 1, 'receivable_account_id', NULL, 5, 1, '2000-01-01')"
             ])

    assert %{rows: [[true]]} =
             query!.("SELECT changed_at > '2026-01-01' FROM finance_receivables_setup_changes")

    for sql <- [
          "UPDATE finance_receivables_setup_changes SET new_value = 6",
          "DELETE FROM finance_receivables_setup_changes",
          "TRUNCATE finance_receivables_setup_changes"
        ] do
      assert_raise Postgrex.Error, ~r/finance receivables keeps/, fn -> query!.(sql) end
    end

    assert_raise Postgrex.Error, ~r/finance_receivables_setup_changes_field/, fn ->
      query!.(
        "INSERT INTO finance_receivables_setup_changes (tenant_id, company_id, field, new_value, changed_by_user_id, changed_at) VALUES (1, 1, 'other', 5, 1, now())"
      )
    end

    # The database stamped the issue and record times it was handed.
    assert %{rows: [[true], [true], [true]]} =
             query!.(
               "SELECT issued_at > '2026-01-01' FROM finance_receivables_documents WHERE status = 'issued' ORDER BY id"
             )

    assert %{rows: [[true]]} =
             query!.("SELECT recorded_at > '2026-01-01' FROM finance_receivables_payments")
  end

  # Entries this module posted before the ledger recorded owners are
  # claimed by the migration, through the ledger's own function.
  @tag :before_claim
  @tag :capture_log
  test "the claim migration marks the module's earlier entries as its own",
       %{repo: repo, migrate_claim!: migrate_claim!} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    entry = fn id, reverses ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 1, '2026-10-01', 'Entry', 'XTS', #{reverses || "NULL"}, 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 5, 110, 0), (1, 1, #{id}, 2, 8, 0, 110)"
      ]
    end

    {:ok, _} =
      in_transaction.(
        [
          "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
          "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (5, 1, 1, '1100', 'Receivable', 'asset', now(), now()), (7, 1, 1, '1000', 'Cash', 'asset', now(), now()), (8, 1, 1, '4000', 'Income', 'income', now(), now()), (9, 1, 1, '2100', 'Tax', 'liability', now(), now())",
          "INSERT INTO finance_receivables_series (id, tenant_id, company_id, code, name, kind, prefix, number_width, inserted_at, updated_at) VALUES (1, 1, 1, 'I', 'Invoices', 'invoice', 'I-', 3, now(), now()), (3, 1, 1, 'P', 'Payments', 'payment', 'P-', 3, now(), now())",
          "INSERT INTO finance_receivables_customers (id, tenant_id, company_id, code, name, inserted_at, updated_at) VALUES (1, 1, 1, 'C1', 'Customer', now(), now())",
          "INSERT INTO finance_receivables_tax_codes (id, tenant_id, company_id, code, name, rate, account_id, inserted_at, updated_at) VALUES (1, 1, 1, 'T', 'Tax', 10, 9, now(), now())"
        ] ++ entry.(1, nil) ++ entry.(2, nil) ++ entry.(3, 2) ++ entry.(4, nil)
      )

    # Invoice 1 posted entry 1; payment 1 posted entry 2, reversed by entry
    # 3; entry 4 is somebody else's.
    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_receivables_documents (id, tenant_id, company_id, kind, status, series_id, customer_id, currency_code, issue_date, subtotal, tax_total, total, inserted_at, updated_at) VALUES (1, 1, 1, 'invoice', 'draft', 1, 1, 'XTS', '2026-10-01', 100, 10, 110, now(), now())",
        "INSERT INTO finance_receivables_document_lines (tenant_id, company_id, document_id, line_number, description, quantity, unit_price, amount, account_id, tax_code_id, tax_rate, tax_amount) VALUES (1, 1, 1, 1, 'Work', 1, 100, 100, 8, 1, 10, 10)",
        "INSERT INTO finance_receivables_document_tax_lines (tenant_id, company_id, document_id, tax_code_id, tax_code, tax_rate, taxable_amount, tax_amount, account_id) VALUES (1, 1, 1, 1, 'T', 10, 100, 10, 9)",
        "UPDATE finance_receivables_documents SET status = 'issued', document_number = 1, document_reference = 'I-001', due_date = '2026-10-31', party_name = 'Customer', receivable_account_id = 5, ledger_entry_id = 1, ledger_entry_number = 1, issued_by_user_id = 1, issued_at = '2000-01-01' WHERE id = 1",
        "INSERT INTO finance_receivables_payments (id, tenant_id, company_id, series_id, customer_id, payment_number, payment_reference, payment_date, amount, currency_code, deposit_account_id, ledger_entry_id, ledger_entry_number, recorded_by_user_id, recorded_at) VALUES (1, 1, 1, 3, 1, 1, 'P-001', '2026-10-02', 110, 'XTS', 7, 2, 2, 1, '2000-01-01')",
        "INSERT INTO finance_receivables_allocations (tenant_id, company_id, payment_id, document_id, amount) VALUES (1, 1, 1, 1, 110)",
        "INSERT INTO finance_receivables_payment_reversals (tenant_id, company_id, payment_id, reversal_date, reason, ledger_entry_id, ledger_entry_number, reversed_by_user_id, reversed_at) VALUES (1, 1, 1, '2026-10-03', 'Bounced', 3, 3, 1, '2000-01-01')"
      ])

    migrate_claim!.()

    assert %{
             rows: [
               [1, true, "finance/receivables", "document:1"],
               [2, true, "finance/receivables", "payment:1"],
               [3, true, "finance/receivables", "payment:1"],
               [4, true, nil, nil]
             ]
           } =
             query!.(
               "SELECT id, legacy, owner_module, owner_record FROM finance_ledger_entries ORDER BY id"
             )
  end
end
