defmodule Bilimbi.Finance.FixedAssets.SchemaContractTest do
  use ExUnit.Case, async: false
  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.FixedAssets.{SchemaContract, TestFixtures}
  alias Ecto.Adapters.{SQL, SQL.Sandbox}

  setup do
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

    :ok =
      Ecto.Migrator.up(Repo, SchemaContract.migration_version(), TestFixtures.migration(),
        log: false,
        dynamic_repo: repo
      )

    Repo.put_dynamic_repo(repo)
    %{repo: repo}
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
end
