defmodule Bilimbi.Finance.Sst.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Sst.SchemaContract
  alias Bilimbi.Finance.Sst.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_sst_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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
             Ecto.Migrator.up(Repo, SchemaContract.migration_version(), TestFixtures.migration(),
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete SST contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migration rolls back", %{repo: repo} do
    assert :ok =
             Ecto.Migrator.down(
               Repo,
               SchemaContract.migration_version(),
               TestFixtures.migration(),
               log: false,
               dynamic_repo: repo
             )

    assert %{rows: [[0]]} =
             SQL.query!(
               repo,
               "SELECT count(*) FROM pg_tables WHERE tablename LIKE 'finance_sst_%'",
               []
             )
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred checks run at commit and a later transaction is a
  # different one. A refused commit disconnects, which Postgrex logs; the log
  # is expected.
  @tag :capture_log
  test "the migration's triggers number, stamp, and keep registrations, returns, and snapshots",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    registration = fn id, months, start ->
      "INSERT INTO finance_sst_registrations (id, tenant_id, company_id, version, sales_tax_number, period_months, period_start, service_tax_basis, recorded_by_user_id, recorded_at) VALUES (#{id}, 1, 1, 99, 'X00-2601-00000001', #{months}, '#{start}', 'payment', 1, '2000-01-01')"
    end

    assert {:ok, _} = in_transaction.([registration.(1, 2, "2026-01-01")])
    assert {:ok, _} = in_transaction.([registration.(2, 2, "2026-01-01")])

    # The database numbers versions and stamps them, whatever was sent.
    assert %{rows: [[1, 1, true], [2, 2, true]]} =
             query!.(
               "SELECT id, version, recorded_at > '2026-01-01' FROM finance_sst_registrations ORDER BY id"
             )

    tax_return = fn id, start, finish, amends ->
      "INSERT INTO finance_sst_returns (id, tenant_id, company_id, return_number, tax_type, registration_id, period_start, period_end, due_date, amends_return_id, reason, opened_by_user_id, opened_at) VALUES (#{id}, 1, 1, 99, 'sales_tax', 2, '#{start}', '#{finish}', '#{finish}'::date + 31, #{amends || "NULL"}, #{if amends, do: "'Late invoice'", else: "NULL"}, 1, '2000-01-01')"
    end

    event = fn return_id, action, extra ->
      {columns, values} =
        case action do
          "finalised" ->
            {", version, through_entry_number, through_mapping_number, through_adjustment_number, currency_code, minor_units, tax_payable",
             ", 99, 5, 0, 0, 'XTS', 2, 10"}

          "discarded" ->
            {", reason", ", 'Wrong period'"}

          "opened" ->
            {"", ""}
        end

      "INSERT INTO finance_sst_return_events (tenant_id, company_id, event_number, return_id, action, recorded_by_user_id, recorded_at#{columns}) VALUES (1, 1, 99, #{return_id}, '#{action}', 1, '2000-01-01'#{values})#{extra}"
    end

    box = fn return_id ->
      "INSERT INTO finance_sst_return_boxes (tenant_id, company_id, return_id, line_number, box, tax_amount) VALUES (1, 1, #{return_id}, 1, '14', 10)"
    end

    assert {:ok, _} =
             in_transaction.([
               tax_return.(1, "2026-01-01", "2026-02-28", nil),
               event.(1, "opened", "")
             ])

    # A return without its opened event is refused at commit.
    assert_raise Postgrex.Error, ~r/has no opened event/, fn ->
      in_transaction.([tax_return.(2, "2026-03-01", "2026-04-30", nil)])
    end

    # A return recorded in an earlier transaction is not opened again.
    assert_raise Postgrex.Error, ~r/is not opened again/, fn ->
      in_transaction.([event.(1, "opened", "")])
    end

    # One open return per tax and period; periods do not overlap.
    assert_raise Postgrex.Error, ~r/already has an open return/, fn ->
      in_transaction.([tax_return.(3, "2026-01-01", "2026-02-28", nil), event.(3, "opened", "")])
    end

    assert_raise Postgrex.Error, ~r/overlaps another period/, fn ->
      in_transaction.([tax_return.(3, "2026-02-01", "2026-03-31", nil), event.(3, "opened", "")])
    end

    # Finalising needs its box figures in the same transaction, and the
    # snapshot takes no row afterwards.
    assert_raise Postgrex.Error, ~r/finalised without its box figures/, fn ->
      in_transaction.([event.(1, "finalised", "")])
    end

    assert {:ok, _} = in_transaction.([event.(1, "finalised", ""), box.(1)])

    assert %{rows: [[1, 1, "opened", nil], [1, 2, "finalised", 1]]} =
             query!.(
               "SELECT return_id, event_number, action, version FROM finance_sst_return_events ORDER BY id"
             )

    assert_raise Postgrex.Error, ~r/is not being finalised/, fn ->
      in_transaction.([String.replace(box.(1), "'14'", "'12'")])
    end

    assert_raise Postgrex.Error, ~r/is already closed/, fn ->
      in_transaction.([event.(1, "discarded", "")])
    end

    # An adjustment is refused on a closed return.
    adjustment = fn return_id ->
      "INSERT INTO finance_sst_return_adjustments (tenant_id, company_id, adjustment_number, return_id, action, box, taxable_amount, tax_amount, description, recorded_by_user_id, recorded_at) VALUES (1, 1, 99, #{return_id}, 'added', '13d', 0, 5, 'Relief', 1, '2000-01-01')"
    end

    assert_raise Postgrex.Error, ~r/is closed: its adjustments are kept/, fn ->
      in_transaction.([adjustment.(1)])
    end

    # A finalised period takes only an amendment of its latest return.
    assert_raise Postgrex.Error, ~r/a new return amends return 1/, fn ->
      in_transaction.([tax_return.(4, "2026-01-01", "2026-02-28", nil), event.(4, "opened", "")])
    end

    assert {:ok, _} =
             in_transaction.([
               tax_return.(4, "2026-01-01", "2026-02-28", 1),
               event.(4, "opened", "")
             ])

    assert {:ok, _} = in_transaction.([adjustment.(4)])

    assert {:ok, _} = in_transaction.([event.(4, "finalised", ""), box.(4)])

    assert %{rows: [[2]]} =
             query!.(
               "SELECT version FROM finance_sst_return_events WHERE return_id = 4 AND action = 'finalised'"
             )

    # The cycle changes only from after the last finalised period.
    assert_raise Postgrex.Error, ~r/reported through 2026-02-28/, fn ->
      in_transaction.([registration.(5, 1, "2026-02-01")])
    end

    assert {:ok, _} = in_transaction.([registration.(5, 1, "2026-03-01")])

    # Nothing is changed, deleted, or truncated.
    for sql <- [
          "UPDATE finance_sst_registrations SET period_months = 3",
          "DELETE FROM finance_sst_returns",
          "UPDATE finance_sst_return_boxes SET tax_amount = 0",
          "DELETE FROM finance_sst_return_adjustments",
          "TRUNCATE finance_sst_mappings"
        ] do
      assert_raise Postgrex.Error, ~r/finance sst keeps/, fn -> in_transaction.([sql]) end
    end

    # Refused rows took no number.
    assert %{rows: [[1, 1], [2, 2], [5, 3]]} =
             query!.("SELECT id, version FROM finance_sst_registrations ORDER BY id")
  end
end
