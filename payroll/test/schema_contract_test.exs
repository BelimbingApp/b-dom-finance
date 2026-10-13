defmodule Bilimbi.Finance.Payroll.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Payroll.SchemaContract
  alias Bilimbi.Finance.Payroll.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup context do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_payroll_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
    {ledger, [owner]} = Enum.split(LedgerFixtures.migrations(), 3)
    [create, claim] = TestFixtures.migrations()
    migrate!.(ledger ++ [create])
    # One test posts before the ledger recorded owners and migrates itself.
    unless context[:before_claim], do: migrate!.([owner, claim])

    %{repo: repo, migrate_claim!: fn -> migrate!.([owner, claim]) end}
  end

  test "the fresh migration implements the complete payroll contract", %{repo: repo} do
    assert Enum.map(TestFixtures.migrations(), &elem(&1, 0)) ==
             SchemaContract.migration_versions()

    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migration rolls back", %{repo: repo} do
    for {version, module} <- Enum.reverse(TestFixtures.migrations()) do
      assert :ok = Ecto.Migrator.down(Repo, version, module, log: false, dynamic_repo: repo)
    end

    assert %{rows: [[0]]} =
             SQL.query!(
               repo,
               "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'finance_payroll_%'",
               []
             )
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox.
  @tag :capture_log
  test "the migration's triggers keep the events whole and the settings in their company",
       %{repo: repo} do
    query! = fn sql -> SQL.query!(repo, sql, []) end

    query!.(
      "INSERT INTO finance_payroll_settings (tenant_id, company_id, net_pay_account_id, claims_payable_account_id, inserted_at, updated_at) VALUES (1, 1, 2, 3, now(), now())"
    )

    assert_raise Postgrex.Error, ~r/in their company/, fn ->
      query!.("UPDATE finance_payroll_settings SET company_id = 2")
    end

    assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
      query!.("DELETE FROM finance_payroll_settings")
    end

    # The writer's own time is replaced by the database's.
    %{rows: [[occurred_at]]} =
      query!.(
        "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, actor_user_id, occurred_at) VALUES (1, 1, 'payroll_run', 1, 'run', 'posted', 1, 1, '2026-09-30', 10, 'XTS', 9, '2000-01-01') RETURNING occurred_at"
      )

    assert occurred_at.year > 2000

    assert_raise Postgrex.Error, ~r/finance_payroll_posting_events_posted_unique/, fn ->
      query!.(
        "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, actor_user_id, occurred_at) VALUES (1, 1, 'payroll_run', 1, 'run', 'posted', 2, 2, '2026-09-30', 10, 'XTS', 9, now())"
      )
    end

    assert_raise Postgrex.Error, ~r/reverses only a posted source/, fn ->
      query!.(
        "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, reason, actor_user_id, occurred_at) VALUES (1, 1, 'claim', 1, 'claim', 'reversed', 3, 3, '2026-09-30', 10, 'XTS', 'why', 9, now())"
      )
    end

    assert_raise Postgrex.Error, ~r/finance_payroll_posting_events_entry/, fn ->
      query!.(
        "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, reason, actor_user_id, occurred_at) VALUES (1, 1, 'claim', 1, 'claim', 'posted', 'why', 9, now())"
      )
    end

    assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
      query!.("UPDATE finance_payroll_posting_events SET reason = 'changed'")
    end
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
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 1, '2026-09-30', 'Entry', 'XTS', #{reverses || "NULL"}, 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 1, 10, 0), (1, 1, #{id}, 2, 2, 0, 10)"
      ]
    end

    event = fn kind, source, name, entry ->
      reason = if name == "reversed", do: "'why'", else: "NULL"

      "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, reason, actor_user_id, occurred_at) VALUES (1, 1, '#{kind}', #{source}, 'ref', '#{name}', #{entry}, #{entry}, '2026-09-30', 10, 'XTS', #{reason}, 9, '2000-01-01')"
    end

    {:ok, _} =
      in_transaction.(
        [
          "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
          "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 1, 1, '1', 'Salaries', 'expense', now(), now()), (2, 1, 1, '2', 'Net pay', 'liability', now(), now())"
        ] ++
          entry.(1, nil) ++
          entry.(2, 1) ++
          entry.(3, nil) ++
          entry.(4, nil) ++
          [
            event.("payroll_run", 7, "posted", 1),
            event.("payroll_run", 7, "reversed", 2),
            event.("claim", 3, "posted", 3)
          ]
      )

    migrate_claim!.()

    assert %{
             rows: [
               [1, true, "finance/payroll", "payroll_run:7"],
               [2, true, "finance/payroll", "payroll_run:7"],
               [3, true, "finance/payroll", "claim:3"],
               [4, true, nil, nil]
             ]
           } =
             query!.(
               "SELECT id, legacy, owner_module, owner_record FROM finance_ledger_entries ORDER BY id"
             )
  end
end
