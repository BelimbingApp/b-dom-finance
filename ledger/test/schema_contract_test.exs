Code.require_file("../priv/repo/migrations/20261012170100_create_finance_ledger.exs", __DIR__)

defmodule Bilimbi.Finance.Ledger.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.Migrations.CreateLedger
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

    assert :ok =
             Ecto.Migrator.up(Repo, SchemaContract.migration_version(), CreateLedger,
               log: false,
               dynamic_repo: repo
             )

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
  test "the migration's triggers keep entries balanced and append-only", %{repo: repo} do
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

    entry = fn id ->
      "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_date, description, currency_code, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, '2026-10-01', 'Entry', 'XTS', 1, now())"
    end

    line = fn entry_id, number, account_id, debit, credit ->
      "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{entry_id}, #{number}, #{account_id}, #{debit}, #{credit})"
    end

    assert {:ok, _} = in_transaction.([entry.(1), line.(1, 1, 1, 10, 0), line.(1, 2, 2, 0, 10)])

    assert_raise Postgrex.Error, ~r/does not balance/, fn ->
      in_transaction.([entry.(2), line.(2, 1, 1, 10, 0), line.(2, 2, 2, 0, 9)])
    end

    assert_raise Postgrex.Error, ~r/has no lines/, fn -> in_transaction.([entry.(3)]) end

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

    assert %{rows: [[2]]} = query!.("SELECT count(*) FROM finance_ledger_entry_lines")
  end
end
