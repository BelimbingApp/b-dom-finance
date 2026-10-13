defmodule Bilimbi.Finance.Reports.SchemaContractTest do
  use ExUnit.Case, async: false
  alias Bilimbi.Base.{Repo, Database.SchemaVerifier}
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    database = "finance_issued_schema_#{String.replace(Ecto.UUID.generate(), "-", "")}"
    Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "CREATE DATABASE \"#{database}\"", []) end)
    repo = Module.concat(__MODULE__, FreshRepo)

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 2},
        id: repo
      )
    )

    migration = Bilimbi.Finance.Reports.Migrations.CreateIssuedReports

    unless Code.ensure_loaded?(migration),
      do:
        Code.require_file(
          Path.expand("../priv/repo/migrations/20261015090000_create_issued_reports.exs", __DIR__)
        )

    assert :ok =
             Ecto.Migrator.up(Repo, 20_261_015_090_000, migration, log: false, dynamic_repo: repo)

    on_exit(fn ->
      Repo.put_dynamic_repo(Repo)

      Sandbox.unboxed_run(Repo, fn ->
        SQL.query!(Repo, "DROP DATABASE \"#{database}\" WITH (FORCE)", [])
      end)
    end)

    %{repo: repo}
  end

  test "the fresh schema keeps issued snapshots immutable and stamps UTC issuance", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, Bilimbi.Finance.Reports.SchemaContract.tables())

    SQL.query!(
      repo,
      "INSERT INTO finance_reports_issued (tenant_id, company_id, kind, implementation_version, through_entry_number, content, chart, layout, membership, issued_by_user_id, issued_at) VALUES (41, 73, 'cash_position', '1', 0, '{}', '[]', '{}', '{}', 91, '2000-01-01')",
      []
    )

    assert %{rows: [[true]]} =
             SQL.query!(repo, "SELECT issued_at > '2026-01-01' FROM finance_reports_issued", [])

    for statement <- [
          "UPDATE finance_reports_issued SET content = '{}'",
          "DELETE FROM finance_reports_issued",
          "TRUNCATE finance_reports_issued"
        ] do
      assert_raise Postgrex.Error, ~r/issued reports are immutable/, fn ->
        SQL.query!(repo, statement, [])
      end
    end
  end
end
