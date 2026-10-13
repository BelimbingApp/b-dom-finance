defmodule Bilimbi.Finance.Reconciliation.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reconciliation.SchemaContract
  alias Bilimbi.Finance.Reconciliation.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup context do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_reconciliation_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
    {ledger, ledger_later} = Enum.split(LedgerFixtures.migrations(), 3)
    [create, claim] = TestFixtures.migrations()
    migrate!.(ledger ++ [create])
    # One test posts before the ledger recorded owners and migrates itself.
    unless context[:before_claim], do: migrate!.(ledger_later ++ [claim])

    %{repo: repo, migrate_claim!: fn -> migrate!.(ledger_later ++ [claim]) end}
  end

  test "the fresh migration implements the complete reconciliation contract", %{repo: repo} do
    assert Enum.map(TestFixtures.migrations(), &elem(&1, 0)) ==
             SchemaContract.migration_versions()

    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred checks run at commit and a later transaction is a
  # different one. A refused commit disconnects, which Postgrex logs; the log
  # is expected.
  @tag :capture_log
  test "the migration's triggers number, stamp, and keep statements, matches, and reconciliations",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_reconciliation_bank_accounts (id, tenant_id, company_id, name, ledger_account_id, import_mapping, inserted_at, updated_at) VALUES (1, 1, 1, 'Operating', 10, '{}', now(), now())"
      ])

    statement = fn id, count ->
      "INSERT INTO finance_reconciliation_statements (id, tenant_id, company_id, bank_account_id, statement_number, file_name, file_sha256, line_count, start_date, end_date, imported_by_user_id, imported_at) VALUES (#{id}, 1, 1, 1, 99, 'f#{id}.csv', repeat('#{id}', 64), #{count}, '2026-10-01', '2026-10-31', 1, '2000-01-01')"
    end

    line = fn statement_id, number, amount ->
      "INSERT INTO finance_reconciliation_statement_lines (id, tenant_id, company_id, statement_id, bank_account_id, line_number, line_date, description, amount, fingerprint) VALUES (#{statement_id * 10 + number}, 1, 1, #{statement_id}, 1, #{number}, '2026-10-0#{number}', 'Line', #{amount}, repeat('#{statement_id}', 63) || '#{number}')"
    end

    assert {:ok, _} = in_transaction.([statement.(1, 2), line.(1, 1, 100), line.(1, 2, -40)])
    assert {:ok, _} = in_transaction.([statement.(2, 1), line.(2, 1, 5)])

    assert_raise Postgrex.Error, ~r/counts 1 lines but holds a different number/, fn ->
      in_transaction.([statement.(3, 1)])
    end

    # A statement recorded in an earlier transaction takes no more lines.
    assert_raise Postgrex.Error, ~r/statement 1 is already recorded/, fn ->
      in_transaction.([line.(1, 3, 1)])
    end

    # Refused statements took no number; the stamps are the database's.
    assert %{rows: [[1, 1, true], [2, 2, true]]} =
             query!.(
               "SELECT id, statement_number, imported_at > '2026-01-01' FROM finance_reconciliation_statements ORDER BY id"
             )

    match = fn id ->
      "INSERT INTO finance_reconciliation_matches (id, tenant_id, company_id, bank_account_id, match_number, matched_by_user_id, matched_at) VALUES (#{id}, 1, 1, 1, 99, 1, '2000-01-01')"
    end

    match_line = fn match_id, line_id ->
      "INSERT INTO finance_reconciliation_match_lines (tenant_id, company_id, match_id, statement_line_id) VALUES (1, 1, #{match_id}, #{line_id})"
    end

    match_entry = fn match_id, entry_id, amount ->
      "INSERT INTO finance_reconciliation_match_entries (tenant_id, company_id, match_id, bank_account_id, entry_id, entry_number, entry_date, description, amount) VALUES (1, 1, #{match_id}, 1, #{entry_id}, #{entry_id}, '2026-10-01', 'Entry', #{amount})"
    end

    event = fn match_id, action, reason ->
      "INSERT INTO finance_reconciliation_match_events (tenant_id, company_id, match_id, action, reason, recorded_by_user_id) VALUES (1, 1, #{match_id}, '#{action}', #{reason}, 1)"
    end

    assert {:ok, _} =
             in_transaction.([
               match.(1),
               match_line.(1, 11),
               match_entry.(1, 501, 100),
               event.(1, "matched", "NULL")
             ])

    assert_raise Postgrex.Error, ~r/statement side 5.0000 differs from ledger side 6.0000/, fn ->
      in_transaction.([
        match.(2),
        match_line.(2, 21),
        match_entry.(2, 502, 6),
        event.(2, "matched", "NULL")
      ])
    end

    assert_raise Postgrex.Error, ~r/match 3 has no matched event/, fn ->
      in_transaction.([match.(3), match_line.(3, 21), match_entry.(3, 502, 5)])
    end

    assert_raise Postgrex.Error, ~r/statement line 11 is already matched/, fn ->
      in_transaction.([
        match.(4),
        match_line.(4, 11),
        match_entry.(4, 503, 100),
        event.(4, "matched", "NULL")
      ])
    end

    assert_raise Postgrex.Error, ~r/ledger entry 501 is already matched on bank account 1/, fn ->
      in_transaction.([
        match.(5),
        match_line.(5, 21),
        match_entry.(5, 501, 5),
        event.(5, "matched", "NULL")
      ])
    end

    # A match recorded earlier takes no more parts and is not matched again.
    assert_raise Postgrex.Error, ~r/match 1 is already recorded/, fn ->
      in_transaction.([match_line.(1, 21)])
    end

    assert_raise Postgrex.Error, ~r/match 1 is already recorded: it is not matched again/, fn ->
      in_transaction.([event.(1, "matched", "NULL")])
    end

    assert_raise Postgrex.Error, ~r/match 6 is not matched/, fn ->
      in_transaction.([
        match.(6),
        match_line.(6, 21),
        match_entry.(6, 504, 5),
        event.(6, "unmatched", "'why'")
      ])
    end

    reconciliation = fn id, end_date ->
      "INSERT INTO finance_reconciliation_reconciliations (id, tenant_id, company_id, bank_account_id, reconciliation_number, end_date, statement_balance, opened_by_user_id, opened_at) VALUES (#{id}, 1, 1, 1, 99, '#{end_date}', 60, 1, '2000-01-01')"
    end

    reconciliation_event = fn id, action, extra ->
      "INSERT INTO finance_reconciliation_reconciliation_events (tenant_id, company_id, reconciliation_id, action, recorded_by_user_id#{extra.columns}) VALUES (1, 1, #{id}, '#{action}', 1#{extra.values})"
    end

    none = %{columns: "", values: ""}

    finalised = %{
      columns:
        ", book_balance, difference, through_entry_number, through_statement_number, through_match_event_number",
      values: ", 60, 0, 501, 2, 1"
    }

    assert_raise Postgrex.Error, ~r/reconciliation 1 has no opened event/, fn ->
      in_transaction.([reconciliation.(1, "2026-10-31")])
    end

    assert {:ok, _} =
             in_transaction.([
               reconciliation.(1, "2026-10-31"),
               reconciliation_event.(1, "opened", none)
             ])

    assert_raise Postgrex.Error, ~r/bank account 1 already has an open reconciliation/, fn ->
      in_transaction.([
        reconciliation.(2, "2026-11-30"),
        reconciliation_event.(2, "opened", none)
      ])
    end

    assert_raise Postgrex.Error,
                 ~r/reconciliation 1 is already recorded: it is not opened again/,
                 fn ->
                   in_transaction.([reconciliation_event.(1, "opened", none)])
                 end

    assert_raise Postgrex.Error, ~r/is not being finalised: an item cannot be added/, fn ->
      in_transaction.([
        "INSERT INTO finance_reconciliation_reconciliation_items (tenant_id, company_id, reconciliation_id, item_number, kind, statement_line_id, item_date, description, amount) VALUES (1, 1, 1, 1, 'statement_line', 21, '2026-10-01', 'Fee', 5)"
      ])
    end

    assert {:ok, _} =
             in_transaction.([
               reconciliation_event.(1, "finalised", finalised),
               "INSERT INTO finance_reconciliation_reconciliation_items (tenant_id, company_id, reconciliation_id, item_number, kind, statement_line_id, item_date, description, amount) VALUES (1, 1, 1, 1, 'statement_line', 21, '2026-10-01', 'Fee', 5)"
             ])

    assert_raise Postgrex.Error, ~r/reconciliation 1 is already closed/, fn ->
      in_transaction.([
        reconciliation_event.(1, "abandoned", %{columns: ", reason", values: ", 'late'"})
      ])
    end

    # The finalised reconciliation counted match 1 (match event 1), which is kept.
    assert_raise Postgrex.Error,
                 ~r/match 1 was counted by a finalised reconciliation and is kept/,
                 fn ->
                   in_transaction.([event.(1, "unmatched", "'changed my mind'")])
                 end

    assert_raise Postgrex.Error,
                 ~r/bank account 1 is already reconciled through 2026-10-31/,
                 fn ->
                   in_transaction.([
                     reconciliation.(3, "2026-10-31"),
                     reconciliation_event.(3, "opened", none)
                   ])
                 end

    assert {:ok, _} =
             in_transaction.([
               reconciliation.(4, "2026-11-30"),
               reconciliation_event.(4, "opened", none)
             ])

    for {sql, message} <- [
          {"UPDATE finance_reconciliation_bank_accounts SET ledger_account_id = 11",
           ~r/keeps its company and ledger account/},
          {"DELETE FROM finance_reconciliation_bank_accounts", ~r/finance reconciliation keeps/},
          {"UPDATE finance_reconciliation_statements SET file_name = 'x'",
           ~r/finance reconciliation keeps/},
          {"DELETE FROM finance_reconciliation_statement_lines",
           ~r/finance reconciliation keeps/},
          {"TRUNCATE finance_reconciliation_statement_lines CASCADE",
           ~r/finance reconciliation keeps/},
          {"UPDATE finance_reconciliation_matches SET note = 'x'",
           ~r/finance reconciliation keeps/},
          {"DELETE FROM finance_reconciliation_match_events", ~r/finance reconciliation keeps/},
          {"TRUNCATE finance_reconciliation_match_entries", ~r/finance reconciliation keeps/},
          {"UPDATE finance_reconciliation_reconciliations SET end_date = '2027-01-01'",
           ~r/finance reconciliation keeps/},
          {"DELETE FROM finance_reconciliation_reconciliation_events",
           ~r/finance reconciliation keeps/},
          {"UPDATE finance_reconciliation_reconciliation_items SET amount = 1",
           ~r/finance reconciliation keeps/},
          {"TRUNCATE finance_reconciliation_reconciliations CASCADE",
           ~r/finance reconciliation keeps/}
        ] do
      assert_raise Postgrex.Error, message, fn -> query!.(sql) end
    end

    # Refused rows took no number; the stamps are the database's.
    assert %{rows: [[1, 1, true]]} =
             query!.(
               "SELECT id, match_number, matched_at > '2026-01-01' FROM finance_reconciliation_matches ORDER BY id"
             )

    assert %{rows: [[1, "matched", 1, true]]} =
             query!.(
               "SELECT match_id, action, event_number, recorded_at > '2026-01-01' FROM finance_reconciliation_match_events ORDER BY event_number"
             )

    assert %{rows: [[1, 1], [4, 2]]} =
             query!.(
               "SELECT id, reconciliation_number FROM finance_reconciliation_reconciliations ORDER BY id"
             )

    assert %{rows: [[1, "opened"], [2, "finalised"], [3, "opened"]]} =
             query!.(
               "SELECT event_number, action FROM finance_reconciliation_reconciliation_events ORDER BY event_number"
             )
  end

  test "the migration's triggers stamp and keep the bank account change log", %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    {:ok, _} =
      Repo.transaction(fn ->
        query!.(
          "INSERT INTO finance_reconciliation_bank_accounts (id, tenant_id, company_id, name, ledger_account_id, import_mapping, inserted_at, updated_at) VALUES (1, 1, 1, 'Operating', 10, '{}', now(), now())"
        )

        query!.(
          "INSERT INTO finance_reconciliation_bank_account_changes (tenant_id, company_id, bank_account_id, field, new_value, changed_by_user_id, changed_at) VALUES (1, 1, 1, 'name', 'Operating', 1, '2000-01-01')"
        )
      end)

    assert %{rows: [[true]]} =
             query!.(
               "SELECT changed_at > '2026-01-01' FROM finance_reconciliation_bank_account_changes"
             )

    for sql <- [
          "UPDATE finance_reconciliation_bank_account_changes SET reason = 'x'",
          "DELETE FROM finance_reconciliation_bank_account_changes",
          "TRUNCATE finance_reconciliation_bank_account_changes"
        ] do
      assert_raise Postgrex.Error, ~r/finance reconciliation keeps/, fn -> query!.(sql) end
    end
  end

  # A statement line's charge or interest entry predates owners: only the
  # match made with it, noted "Posted from statement line as ...", names it.
  @tag :before_claim
  @tag :capture_log
  test "the claim migration marks the entries statement lines posted as the module's own",
       %{repo: repo, migrate_claim!: migrate_claim!} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    entry = fn id, reverses ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, #{id}, '2026-09-30', 'Entry', 'XTS', #{reverses || "NULL"}, 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 1, 10, 0), (1, 1, #{id}, 2, 2, 0, 10)"
      ]
    end

    statement_line = fn id ->
      "INSERT INTO finance_reconciliation_statement_lines (id, tenant_id, company_id, statement_id, bank_account_id, line_number, line_date, description, amount, fingerprint) VALUES (#{id}, 1, 1, 1, 1, #{id}, '2026-09-30', 'Line', -10, repeat('#{id}', 64))"
    end

    match = fn id, note ->
      "INSERT INTO finance_reconciliation_matches (id, tenant_id, company_id, bank_account_id, match_number, note, matched_by_user_id, matched_at) VALUES (#{id}, 1, 1, 1, 99, #{note}, 1, '2000-01-01')"
    end

    part = fn match_id, line_id, entry_id ->
      [
        "INSERT INTO finance_reconciliation_match_lines (tenant_id, company_id, match_id, statement_line_id) VALUES (1, 1, #{match_id}, #{line_id})",
        "INSERT INTO finance_reconciliation_match_entries (tenant_id, company_id, match_id, bank_account_id, entry_id, entry_number, entry_date, description, amount) VALUES (1, 1, #{match_id}, 1, #{entry_id}, #{entry_id}, '2026-09-30', 'Entry', -10)",
        "INSERT INTO finance_reconciliation_match_events (tenant_id, company_id, match_id, action, recorded_by_user_id) VALUES (1, 1, #{match_id}, 'matched', 1)"
      ]
    end

    posted = "'Posted from statement line as charge'"

    {:ok, _} =
      in_transaction.(
        [
          "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
          "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 1, 1, '1', 'Charges', 'expense', now(), now()), (2, 1, 1, '2', 'Bank', 'asset', now(), now())",
          "INSERT INTO finance_reconciliation_bank_accounts (id, tenant_id, company_id, name, ledger_account_id, import_mapping, inserted_at, updated_at) VALUES (1, 1, 1, 'Operating', 2, '{}', now(), now())",
          "INSERT INTO finance_reconciliation_statements (id, tenant_id, company_id, bank_account_id, statement_number, file_name, file_sha256, line_count, start_date, end_date, imported_by_user_id, imported_at) VALUES (1, 1, 1, 1, 99, 'f.csv', repeat('1', 64), 5, '2026-09-01', '2026-09-30', 1, '2000-01-01')"
        ] ++
          Enum.flat_map(1..6, &entry.(&1, nil)) ++
          Enum.map(1..5, statement_line) ++
          [match.(1, posted)] ++
          part.(1, 1, 1) ++
          [match.(2, "'Matched by hand'")] ++
          part.(2, 2, 2) ++
          [match.(3, posted)] ++
          part.(3, 3, 3) ++
          [match.(5, posted)] ++
          part.(5, 5, 5)
      )

    # The line was unmatched and posted again before one entry per line was
    # kept: two posting matches name it, so neither entry is claimed.
    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_reconciliation_match_events (tenant_id, company_id, match_id, action, reason, recorded_by_user_id) VALUES (1, 1, 3, 'unmatched', 'Wrong kind', 1)"
      ])

    {:ok, _} = in_transaction.([match.(4, posted)] ++ part.(4, 3, 4))

    migrate_claim!.()

    assert %{
             rows: [
               [1, true, "finance/reconciliation", "statement_line:1"],
               [2, true, nil, nil],
               [3, true, nil, nil],
               [4, true, nil, nil],
               [5, true, "finance/reconciliation", "statement_line:5"],
               [6, true, nil, nil]
             ]
           } =
             query!.(
               "SELECT id, legacy, owner_module, owner_record FROM finance_ledger_entries ORDER BY id"
             )
  end
end
