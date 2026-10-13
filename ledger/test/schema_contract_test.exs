Code.require_file("../priv/repo/migrations/20261012170100_create_finance_ledger.exs", __DIR__)

Code.require_file(
  "../priv/repo/migrations/20261012214100_notify_finance_ledger_postings.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261013101700_create_finance_ledger_closing.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261015150000_add_finance_ledger_entry_owner.exs",
  __DIR__
)

defmodule Bilimbi.Finance.Ledger.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.Migrations.{AddEntryOwner, CreateClosing, CreateLedger}
  alias Bilimbi.Finance.Ledger.Migrations.NotifyPostings
  alias Bilimbi.Finance.Ledger.Postings
  alias Bilimbi.Finance.Ledger.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup context do
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

    [earlier, owner] =
      SchemaContract.migration_versions()
      |> Enum.zip([CreateLedger, NotifyPostings, CreateClosing, AddEntryOwner])
      |> Enum.split(3)
      |> Tuple.to_list()

    migrate! = fn migrations ->
      for {version, migration} <- migrations do
        assert :ok = Ecto.Migrator.up(Repo, version, migration, log: false, dynamic_repo: repo)
      end
    end

    migrate!.(earlier)
    # One test posts entries before owners were recorded and migrates itself.
    unless context[:before_owner], do: migrate!.(owner)

    %{repo: repo, database: database, migrate_owner!: fn -> migrate!.(owner) end}
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

  # PostgreSQL delivers a notification at commit only, which no sandboxed
  # suite can show; this listens on the fresh database the way the ledger's
  # relay does.
  @tag :capture_log
  test "the migration announces a committed entry and nothing for a refused one",
       %{repo: repo, database: database} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    listener =
      start_supervised!(
        {Postgrex.Notifications,
         Repo.config()
         |> Keyword.drop([:pool, :pool_size, :name])
         |> Keyword.put(:database, database)}
      )

    {:ok, _ref} = Postgrex.Notifications.listen(listener, Postings.channel())

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (7, 3, 'XTS', 2, now())",
        "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 7, 3, '1', 'Debit', 'asset', now(), now()), (2, 7, 3, '2', 'Credit', 'income', now(), now())"
      ])

    entry =
      "INSERT INTO finance_ledger_entries (tenant_id, company_id, entry_number, entry_date, description, currency_code, posted_by_user_id, posted_at) VALUES (7, 3, 1, '2026-10-01', 'Entry', 'XTS', 1, now()) RETURNING id"

    post = fn credit ->
      Repo.transaction(fn ->
        %{rows: [[id]]} = query!.(entry)

        for {account, debit, credit} <- [{1, 10, 0}, {2, 0, credit}] do
          query!.(
            "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (7, 3, #{id}, #{account}, #{account}, #{debit}, #{credit})"
          )
        end
      end)
    end

    assert {:ok, _} = post.(10)
    assert_receive {:notification, ^listener, _ref, "finance_ledger_postings", "7:3:1"}

    assert_raise Postgrex.Error, ~r/does not balance/, fn -> post.(9) end

    assert {:error, :rolled_back} =
             Repo.transaction(fn -> query!.(entry) && Repo.rollback(:rolled_back) end)

    assert {:ok, _} = post.(10)
    assert_receive {:notification, ^listener, _ref, "finance_ledger_postings", "7:3:2"}
    refute_received {:notification, _, _, _, _}
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

  # Entries posted before the owner migration are legacy: an owning module's
  # migration claims each of its own once, and the row changes in no other
  # way. The migration's own triggers prove it here, outside the sandbox.
  @tag :before_owner
  @tag :capture_log
  test "the owner migration marks earlier entries legacy and lets an owner claim each once",
       %{repo: repo, migrate_owner!: migrate_owner!} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    entry = fn id, reverses ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 1, '2026-10-01', 'Entry', 'XTS', #{reverses || "NULL"}, 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 1, 10, 0), (1, 1, #{id}, 2, 2, 0, 10)"
      ]
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
        "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 1, 1, '1', 'Debit', 'asset', now(), now()), (2, 1, 1, '2', 'Credit', 'income', now(), now())"
      ])

    {:ok, _} = in_transaction.(entry.(1, nil))
    {:ok, _} = in_transaction.(entry.(2, 1))
    {:ok, _} = in_transaction.(entry.(3, nil))

    migrate_owner!.()

    assert %{rows: [[1, true, nil], [2, true, nil], [3, true, nil]]} =
             query!.("SELECT id, legacy, owner_module FROM finance_ledger_entries ORDER BY id")

    claim = fn id, module, record ->
      "SELECT finance_ledger_claim_legacy_entry(#{id}, 1, '#{module}', '#{record}')"
    end

    assert {:ok, _} = in_transaction.([claim.(1, "finance/receivables", "payment:5")])
    # Claiming again by the same owner is nothing; by another is refused.
    assert {:ok, _} = in_transaction.([claim.(1, "finance/receivables", "payment:5")])

    assert_raise Postgrex.Error, ~r/not an unclaimed legacy entry/, fn ->
      in_transaction.([claim.(1, "finance/payables", "payment:5")])
    end

    # The reversal takes its original's owner and no other.
    assert_raise Postgrex.Error, ~r/have one owner/, fn ->
      in_transaction.([claim.(2, "finance/payables", "payment:9")])
    end

    assert {:ok, _} = in_transaction.([claim.(2, "finance/receivables", "payment:5")])

    assert_raise Postgrex.Error, ~r/does not exist/, fn ->
      in_transaction.([claim.(99, "finance/receivables", "payment:5")])
    end

    # A new entry is not legacy; its row never changes, owner included.
    {:ok, _} = in_transaction.(entry.(4, nil))

    assert_raise Postgrex.Error, ~r/not an unclaimed legacy entry/, fn ->
      in_transaction.([claim.(4, "finance/receivables", "payment:6")])
    end

    for sql <- [
          "UPDATE finance_ledger_entries SET owner_module = 'finance/receivables', owner_record = 'payment:7' WHERE id = 4",
          "UPDATE finance_ledger_entries SET owner_module = 'finance/payables', owner_record = 'payment:8' WHERE id = 1",
          "UPDATE finance_ledger_entries SET owner_module = 'finance/receivables', owner_record = 'payment:9', description = 'x' WHERE id = 3",
          "UPDATE finance_ledger_entries SET owner_module = NULL, owner_record = NULL WHERE id = 1",
          "UPDATE finance_ledger_entries SET legacy = false WHERE id = 3"
        ] do
      assert_raise Postgrex.Error, ~r/finance ledger keeps/, fn -> query!.(sql) end
    end

    assert %{
             rows: [
               [1, "finance/receivables", "payment:5"],
               [2, "finance/receivables", "payment:5"],
               [3, nil, nil],
               [4, nil, nil]
             ]
           } =
             query!.(
               "SELECT id, owner_module, owner_record FROM finance_ledger_entries ORDER BY id"
             )

    # One original entry per owned record; a reversal carries its original's owner.
    owned = fn id, reverses, module, record ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, owner_module, owner_record, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 1, '2026-10-02', 'Entry', 'XTS', #{reverses || "NULL"}, #{module}, #{record}, 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 1, 10, 0), (1, 1, #{id}, 2, 2, 0, 10)"
      ]
    end

    assert_raise Postgrex.Error, ~r/finance_ledger_entries_owner_record_unique/, fn ->
      in_transaction.(owned.(5, nil, "'finance/receivables'", "'payment:5'"))
    end

    assert {:ok, _} = in_transaction.(owned.(5, nil, "'finance/einvoice'", "'document:3'"))

    assert_raise Postgrex.Error, ~r/is reversed through that module/, fn ->
      in_transaction.(owned.(6, 5, "NULL", "NULL"))
    end

    assert_raise Postgrex.Error, ~r/is reversed through that module/, fn ->
      in_transaction.(owned.(6, 5, "'finance/einvoice'", "'document:4'"))
    end

    assert_raise Postgrex.Error, ~r/has no owner: its reversal has none either/, fn ->
      in_transaction.(owned.(6, 3, "'finance/einvoice'", "'document:3'"))
    end

    assert {:ok, _} = in_transaction.(owned.(6, 5, "'finance/einvoice'", "'document:3'"))

    for sql <- [
          "INSERT INTO finance_ledger_entries (tenant_id, company_id, entry_number, entry_date, description, currency_code, owner_module, posted_by_user_id, posted_at) VALUES (1, 1, 1, '2026-10-02', 'Entry', 'XTS', 'finance/einvoice', 1, now())",
          "INSERT INTO finance_ledger_entries (tenant_id, company_id, entry_number, entry_date, description, currency_code, owner_module, owner_record, posted_by_user_id, posted_at) VALUES (1, 1, 1, '2026-10-02', 'Entry', 'XTS', 'Finance/Einvoice', 'document:3', 1, now())",
          "INSERT INTO finance_ledger_entries (tenant_id, company_id, entry_number, entry_date, description, currency_code, owner_module, owner_record, posted_by_user_id, posted_at) VALUES (1, 1, 1, '2026-10-02', 'Entry', 'XTS', 'finance/einvoice', 'document 3', 1, now())"
        ] do
      assert_raise Postgrex.Error, ~r/finance_ledger_entries_owner_/, fn ->
        in_transaction.([sql])
      end
    end
  end
end
