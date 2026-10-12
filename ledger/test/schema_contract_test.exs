Code.require_file("../priv/repo/migrations/20261012170100_create_finance_ledger.exs", __DIR__)

Code.require_file(
  "../priv/repo/migrations/20261012214100_notify_finance_ledger_postings.exs",
  __DIR__
)

defmodule Bilimbi.Finance.Ledger.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.Migrations.{CreateLedger, NotifyPostings}
  alias Bilimbi.Finance.Ledger.Postings
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

    for {version, migration} <- [
          {SchemaContract.migration_version(), CreateLedger},
          {20_261_012_214_100, NotifyPostings}
        ] do
      assert :ok = Ecto.Migrator.up(Repo, version, migration, log: false, dynamic_repo: repo)
    end

    %{repo: repo, database: database}
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
end
