defmodule Bilimbi.Finance.FixedAssets.SchemaContractTest do
  use ExUnit.Case, async: false
  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.FixedAssets.{SchemaContract, TestFixtures}
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Ecto.Adapters.{SQL, SQL.Sandbox}

  setup context do
    database = "bilimbi_assets_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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

    Repo.put_dynamic_repo(repo)
    %{repo: repo, migrate_claim!: fn -> migrate!.(ledger_later ++ [claim]) end}
  end

  test "the migrations are the contract's, in order" do
    assert Enum.map(TestFixtures.migrations(), &elem(&1, 0)) ==
             SchemaContract.migration_versions()
  end

  test "fresh migration implements the structural contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  defp category!(repo) do
    SQL.query!(
      repo,
      "INSERT INTO finance_fixed_assets_categories (id, tenant_id, company_id, name, recorded_by_user_id) VALUES (1,41,73,'Category',91)",
      []
    )

    SQL.query!(
      repo,
      "INSERT INTO finance_fixed_assets_category_revisions (id,tenant_id,company_id,category_id,cost_account_id,accumulated_account_id,expense_account_id,gain_account_id,loss_account_id,method,life_months,reason,recorded_by_user_id) VALUES (1,41,73,1,1,2,3,4,5,'straight_line',12,'Initial',91)",
      []
    )
  end

  defp asset_sql(id),
    do:
      "INSERT INTO finance_fixed_assets_assets (id,tenant_id,company_id,asset_number,category_revision_id,description,acquisition_date,in_service_date,cost,residual_value,method,life_months,entry_id,entry_number,entry_line_number,recorded_by_user_id,recorded_at) VALUES (#{id},41,73,99,1,'Asset','2026-01-01','2026-01-01',1200,0,'straight_line',12,#{id},#{id},1,91,'2000-01-01')"

  test "asset numbers are gapless after rollback; timestamp is database assigned; permanent retention is enforced",
       %{repo: repo} do
    category!(repo)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               SQL.query!(repo, asset_sql(1), [])
               Repo.rollback(:cancelled)
             end)

    SQL.query!(repo, asset_sql(2), [])

    assert %{rows: [[1, true]]} =
             SQL.query!(
               repo,
               "SELECT asset_number, recorded_at > '2026-01-01' FROM finance_fixed_assets_assets",
               []
             )

    for sql <- [
          "UPDATE finance_fixed_assets_assets SET description = 'Changed'",
          "DELETE FROM finance_fixed_assets_assets",
          "TRUNCATE finance_fixed_assets_assets CASCADE",
          "DELETE FROM finance_fixed_assets_category_revisions"
        ] do
      assert_raise Postgrex.Error, ~r/retain every record/, fn -> SQL.query!(repo, sql, []) end
    end

    assert %{rows: [[1]]} =
             SQL.query!(repo, "SELECT count(*) FROM finance_fixed_assets_assets", [])
  end

  @tag :capture_log
  test "run total is checked at commit and a later transaction cannot append items", %{repo: repo} do
    category!(repo)
    SQL.query!(repo, asset_sql(1), [])

    run =
      "INSERT INTO finance_fixed_assets_runs (id,tenant_id,company_id,period,total,entry_id,entry_number,recorded_by_user_id) VALUES (1,41,73,'2026-01-01',100,2,2,91)"

    item =
      "INSERT INTO finance_fixed_assets_run_items (tenant_id,company_id,run_id,asset_id,amount,recorded_by_user_id) VALUES (41,73,1,1,100,91)"

    assert_raise Postgrex.Error, ~r/total differs/, fn ->
      Repo.transaction(fn -> SQL.query!(repo, run, []) end)
    end

    assert {:ok, _} =
             Repo.transaction(fn ->
               SQL.query!(repo, run, [])
               SQL.query!(repo, item, [])
             end)

    assert_raise Postgrex.Error, ~r/already recorded/, fn -> SQL.query!(repo, item, []) end

    assert_raise Postgrex.Error, ~r/already recorded/, fn ->
      SQL.query!(
        repo,
        "INSERT INTO finance_fixed_assets_run_exceptions (tenant_id,company_id,run_id,asset_id,recorded_by_user_id) VALUES (41,73,1,1,91)",
        []
      )
    end

    assert_raise Postgrex.Error, ~r/runs_period/, fn ->
      SQL.query!(repo, String.replace(run, "(1,41", "(2,41"), [])
    end
  end

  test "events retain disposal standing and reversals and refuse invalid transitions", %{
    repo: repo
  } do
    category!(repo)
    SQL.query!(repo, asset_sql(1), [])

    dispose =
      "INSERT INTO finance_fixed_assets_events (tenant_id,company_id,event_number,asset_id,action,effective_date,entry_id,entry_number,proceeds,accumulated,reason,recorded_by_user_id) VALUES (41,73,99,1,'disposed','2026-01-01',2,2,0,0,'Write off',91) RETURNING id"

    %{rows: [[id]]} = SQL.query!(repo, dispose, [])
    assert_raise Postgrex.Error, ~r/already disposed/, fn -> SQL.query!(repo, dispose, []) end

    SQL.query!(
      repo,
      "INSERT INTO finance_fixed_assets_events (tenant_id,company_id,event_number,asset_id,action,effective_date,entry_id,entry_number,reverses_event_id,reason,recorded_by_user_id) VALUES (41,73,99,1,'disposal_reversed','2026-01-02',3,3,$1,'Correct',91)",
      [id]
    )

    assert %{rows: [[1], [2]]} =
             SQL.query!(
               repo,
               "SELECT event_number FROM finance_fixed_assets_events ORDER BY event_number",
               []
             )

    assert_raise Postgrex.Error, ~r/retain every record/, fn ->
      SQL.query!(repo, "DELETE FROM finance_fixed_assets_events", [])
    end
  end

  test "a voided acquisition is recorded once, entry-less only when nothing was reversed, and blocks disposal",
       %{repo: repo} do
    category!(repo)
    SQL.query!(repo, asset_sql(1), [])

    void = fn accumulated, entry ->
      "INSERT INTO finance_fixed_assets_events (tenant_id,company_id,asset_id,action,effective_date,entry_id,entry_number,accumulated,reason,recorded_by_user_id) VALUES (41,73,1,'acquisition_voided','2026-02-01',#{entry},#{entry},#{accumulated},'Cancelled',91)"
    end

    assert_raise Postgrex.Error, ~r/entry_check/, fn ->
      SQL.query!(repo, void.(100, "NULL"), [])
    end

    SQL.query!(repo, void.(0, "NULL"), [])
    assert_raise Postgrex.Error, ~r/events_void/, fn -> SQL.query!(repo, void.(0, "NULL"), []) end

    assert_raise Postgrex.Error, ~r/acquisition voided/, fn ->
      SQL.query!(
        repo,
        "INSERT INTO finance_fixed_assets_events (tenant_id,company_id,asset_id,action,effective_date,entry_id,entry_number,proceeds,accumulated,reason,recorded_by_user_id) VALUES (41,73,1,'disposed','2026-02-02',2,2,0,0,'Write off',91)",
        []
      )
    end
  end

  # Runs, disposals, and voids posted before the ledger recorded owners are
  # claimed by the migration, through the ledger's own function; a run's
  # reversal follows its run, and an acquisition entry is never claimed.
  @tag :before_claim
  @tag :capture_log
  test "the claim migration marks the module's earlier entries as its own",
       %{repo: repo, migrate_claim!: migrate_claim!} do
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    entry = fn id, reverses ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, posted_by_user_id, posted_at) VALUES (#{id}, 41, 73, 1, '2026-01-31', 'Entry', 'XTS', #{reverses || "NULL"}, 91, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (41, 73, #{id}, 1, 3, 100, 0), (41, 73, #{id}, 2, 2, 0, 100)"
      ]
    end

    {:ok, _} =
      in_transaction.(
        [
          "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (41, 73, 'XTS', 2, now())",
          "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 41, 73, '1500', 'Cost', 'asset', now(), now()), (2, 41, 73, '1590', 'Accumulated', 'asset', now(), now()), (3, 41, 73, '6000', 'Depreciation', 'expense', now(), now())"
        ] ++ entry.(1, nil) ++ entry.(2, nil) ++ entry.(3, 2) ++ entry.(4, nil) ++ entry.(5, nil)
      )

    category!(repo)
    query!.(asset_sql(1))

    # Run 1 posted entry 2, reversed by entry 3; the asset was disposed with
    # entry 4; entry 1 is the acquisition and entry 5 somebody else's.
    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_fixed_assets_runs (id, tenant_id, company_id, period, entry_id, entry_number, total, recorded_by_user_id, recorded_at) VALUES (1, 41, 73, '2026-01-01', 2, 2, 100, 91, '2000-01-01')",
        "INSERT INTO finance_fixed_assets_run_items (tenant_id, company_id, run_id, asset_id, amount, recorded_by_user_id, recorded_at) VALUES (41, 73, 1, 1, 100, 91, '2000-01-01')",
        "INSERT INTO finance_fixed_assets_events (id, tenant_id, company_id, event_number, run_id, action, effective_date, entry_id, entry_number, reason, recorded_by_user_id, recorded_at) VALUES (1, 41, 73, 1, 1, 'run_reversed', '2026-02-01', 3, 3, 'Wrong', 91, '2000-01-01')",
        "INSERT INTO finance_fixed_assets_events (id, tenant_id, company_id, event_number, asset_id, action, effective_date, entry_id, entry_number, proceeds, accumulated, reason, recorded_by_user_id, recorded_at) VALUES (2, 41, 73, 2, 1, 'disposed', '2026-02-02', 4, 4, 0, 0, 'Scrapped', 91, '2000-01-01')"
      ])

    migrate_claim!.()

    assert %{
             rows: [
               [1, true, nil, nil],
               [2, true, "finance/fixed_assets", "run:1"],
               [3, true, "finance/fixed_assets", "run:1"],
               [4, true, "finance/fixed_assets", "event:2"],
               [5, true, nil, nil]
             ]
           } =
             query!.(
               "SELECT id, legacy, owner_module, owner_record FROM finance_ledger_entries ORDER BY id"
             )
  end
end
