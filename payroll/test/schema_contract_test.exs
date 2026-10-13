defmodule Bilimbi.Finance.Payroll.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Payroll.SchemaContract
  alias Bilimbi.Finance.Payroll.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
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

    for {version, module} <- TestFixtures.migrations() do
      assert :ok = Ecto.Migrator.up(Repo, version, module, log: false, dynamic_repo: repo)
    end

    %{repo: repo}
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
end
