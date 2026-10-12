Code.require_file("../priv/repo/migrations/20261012170100_create_finance_ledger.exs", __DIR__)

Code.require_file(
  "../priv/repo/migrations/20261013101700_create_finance_ledger_closing.exs",
  __DIR__
)

defmodule Bilimbi.Finance.Ledger.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.Migrations.{CreateClosing, CreateLedger}
  alias Bilimbi.Finance.Ledger.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_ledger_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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

    for {version, migration} <-
          Enum.zip(SchemaContract.migration_versions(), [CreateLedger, CreateClosing]) do
      assert :ok = Ecto.Migrator.up(Repo, version, migration, log: false, dynamic_repo: repo)
    end

    %{repo: repo}
  end

  test "the fresh migration implements the complete ledger contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred balance check runs at commit. A refused commit
  # disconnects, which Postgrex logs; the log is expected.
  @tag :capture_log
  test "the migration's triggers keep entries balanced, numbered, append-only, and closed",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
        "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 1, 1, '1', 'Debit', 'asset', now(), now()), (2, 1, 1, '2', 'Credit', 'income', now(), now())"
      ])

    # The writer's own number and posting time are replaced by the database's.
    entry = fn id ->
      "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 99, '2026-10-01', 'Entry', 'XTS', 1, '2000-01-01')"
    end

    line = fn entry_id, number, account_id, debit, credit ->
      "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{entry_id}, #{number}, #{account_id}, #{debit}, #{credit})"
    end

    assert {:ok, _} = in_transaction.([entry.(1), line.(1, 1, 1, 10, 0), line.(1, 2, 2, 0, 10)])

    assert_raise Postgrex.Error, ~r/does not balance/, fn ->
      in_transaction.([entry.(2), line.(2, 1, 1, 10, 0), line.(2, 2, 2, 0, 9)])
    end

    assert_raise Postgrex.Error, ~r/has no lines/, fn -> in_transaction.([entry.(3)]) end

    assert_raise Postgrex.Error, ~r/already posted/, fn ->
      in_transaction.([line.(1, 3, 1, 5, 0), line.(1, 4, 2, 0, 5)])
    end

    assert {:ok, _} =
             in_transaction.([
               entry.(4),
               line.(4, 1, 1, 10, 0),
               line.(4, 2, 2, 0, 4),
               line.(4, 3, 2, 0, 6)
             ])

    for sql <- [
          "UPDATE finance_ledger_entries SET description = 'x'",
          "DELETE FROM finance_ledger_entry_lines",
          "TRUNCATE finance_ledger_entry_lines",
          "UPDATE finance_ledger_books SET minor_units = 0",
          "DELETE FROM finance_ledger_accounts WHERE id = 2"
        ] do
      assert_raise Postgrex.Error, ~r/finance ledger keeps/, fn -> query!.(sql) end
    end

    assert_raise Postgrex.Error, ~r/keeps its company, code and type/, fn ->
      query!.("UPDATE finance_ledger_accounts SET code = '9' WHERE id = 1")
    end

    assert %{rows: [[5]]} = query!.("SELECT count(*) FROM finance_ledger_entry_lines")

    # Refused transactions consumed no number: the two posted entries are 1 and 2.
    assert %{rows: [[1, 1, true], [4, 2, true]]} =
             query!.(
               "SELECT id, entry_number, posted_at > '2026-01-01' FROM finance_ledger_entries ORDER BY id"
             )
  end

  # The closing rules as the migration carries them: the deferred checks run
  # at a real commit here, which the module's sandboxed suites never reach.
  @tag :capture_log
  test "the migration's triggers keep fiscal years divided and closed years closed",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
        "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 1, 1, '1', 'Debit', 'asset', now(), now()), (2, 1, 1, '2', 'Credit', 'income', now(), now())"
      ])

    year = fn id, start ->
      "INSERT INTO finance_ledger_fiscal_years (id, tenant_id, company_id, start_date, end_date, opened_by_user_id, opened_at) VALUES (#{id}, 1, 1, '#{start}', ('#{start}'::date + interval '2 months' - interval '1 day')::date, 1, '2000-01-01')"
    end

    period = fn year_id, number, start ->
      "INSERT INTO finance_ledger_periods (tenant_id, company_id, fiscal_year_id, period_number, start_date, end_date) VALUES (1, 1, #{year_id}, #{number}, '#{start}', ('#{start}'::date + interval '1 month' - interval '1 day')::date)"
    end

    # A period is named by its number: refused inserts consumed IDs.
    event = fn year_id, number, action ->
      period_id =
        if number,
          do: "(SELECT id FROM finance_ledger_periods WHERE period_number = #{number})",
          else: "NULL"

      "INSERT INTO finance_ledger_closing_events (tenant_id, company_id, event_number, fiscal_year_id, period_id, action, reason, recorded_by_user_id, recorded_at) VALUES (1, 1, 99, #{year_id}, #{period_id}, '#{action}', 'Reason', 1, '2000-01-01')"
    end

    entry = fn id, date ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 1, '#{date}', 'Entry', 'XTS', 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 1, 10, 0), (1, 1, #{id}, 2, 2, 0, 10)"
      ]
    end

    assert_raise Postgrex.Error, ~r/not divided into periods through its end/, fn ->
      in_transaction.([year.(1, "2026-01-01"), period.(1, 1, "2026-01-01")])
    end

    assert {:ok, _} =
             in_transaction.([
               year.(1, "2026-01-01"),
               period.(1, 1, "2026-01-01"),
               period.(1, 2, "2026-02-01")
             ])

    assert_raise Postgrex.Error, ~r/already open: a period cannot be added/, fn ->
      in_transaction.([period.(1, 3, "2026-03-01")])
    end

    assert_raise Postgrex.Error, ~r/day after the previous one ends/, fn ->
      in_transaction.([year.(2, "2026-04-01")])
    end

    assert {:ok, _} = in_transaction.(entry.(1, "2026-01-15"))
    assert {:ok, _} = in_transaction.([event.(1, 1, "close")])

    assert_raise Postgrex.Error, ~r/falls in a closed period/, fn ->
      in_transaction.(entry.(2, "2026-01-20"))
    end

    assert_raise Postgrex.Error, ~r/before the first fiscal year/, fn ->
      in_transaction.(entry.(3, "2025-12-31"))
    end

    assert_raise Postgrex.Error, ~r/closes with the year/, fn ->
      in_transaction.([event.(1, 2, "close")])
    end

    assert_raise Postgrex.Error, ~r/closed but has an open period/, fn ->
      in_transaction.([event.(1, nil, "close")])
    end

    assert {:ok, _} = in_transaction.([event.(1, nil, "close"), event.(1, 2, "close")])

    assert_raise Postgrex.Error, ~r/in a closed fiscal year: reopen the year/, fn ->
      in_transaction.([event.(1, 2, "reopen")])
    end

    for sql <- [
          "UPDATE finance_ledger_closing_events SET action = 'reopen'",
          "DELETE FROM finance_ledger_periods",
          "TRUNCATE finance_ledger_fiscal_years CASCADE"
        ] do
      assert_raise Postgrex.Error, ~r/finance ledger keeps/, fn -> query!.(sql) end
    end

    # The database numbers events 1, 2, 3 and stamps them; refused ones took none.
    assert %{rows: [[1, true], [2, true], [3, true]]} =
             query!.(
               "SELECT event_number, recorded_at > '2026-01-01' FROM finance_ledger_closing_events ORDER BY id"
             )
  end
end
