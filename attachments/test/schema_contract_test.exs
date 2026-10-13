defmodule Bilimbi.Finance.Attachments.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Attachments.SchemaContract
  alias Bilimbi.Finance.Attachments.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_attachments_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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

  test "the fresh migration implements the complete attachments contract", %{repo: repo} do
    assert Enum.map(TestFixtures.migrations(), &elem(&1, 0)) ==
             SchemaContract.migration_versions()

    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migration rolls back whole", %{repo: repo} do
    for {version, module} <- Enum.reverse(TestFixtures.migrations()) do
      assert :ok = Ecto.Migrator.down(Repo, version, module, log: false, dynamic_repo: repo)
    end

    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT tablename FROM pg_tables WHERE tablename LIKE 'finance_attachment%'",
        []
      )

    assert rows == []
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them.
  test "the migration's triggers number, stamp, and keep attachments and their events",
       %{repo: repo} do
    query! = fn sql -> SQL.query!(repo, sql, []) end

    attachment = fn id, document ->
      "INSERT INTO finance_attachments (id, tenant_id, company_id, attachment_number, source, source_module, document_id, document_label, document_date, artifact_id, file_name, content_type, byte_size, sha256, retention_years, retain_until, captured_by_user_id, captured_at) VALUES (#{id}, 1, 1, 99, 'finance/test/record', 'Elixir.Test', #{document}, 'Record', '2026-10-01', gen_random_uuid(), 'f.txt', 'text/plain', 3, repeat('a', 64), 7, '2033-12-31 23:59:59', 9, '2000-01-01') RETURNING attachment_number, captured_at"
    end

    %{rows: [[1, captured_at]]} = query!.(attachment.(1, 1))
    assert captured_at.year > 2000
    %{rows: [[2, _]]} = query!.(attachment.(2, 1))
    %{rows: [[3, _]]} = query!.(attachment.(3, 2))

    assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
      query!.("UPDATE finance_attachments SET file_name = 'g.txt' WHERE id = 1")
    end

    assert_raise Postgrex.Error, ~r/same record/, fn ->
      query!.(
        "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, replacement_id, actor_user_id, occurred_at) VALUES (1, 1, 1, 'replaced', 3, 9, now())"
      )
    end

    %{rows: [[occurred_at]]} =
      query!.(
        "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, replacement_id, actor_user_id, occurred_at) VALUES (1, 1, 1, 'replaced', 2, 9, '2000-01-01') RETURNING occurred_at"
      )

    assert occurred_at.year > 2000

    assert_raise Postgrex.Error, ~r/finance_attachment_events_standing_unique/, fn ->
      query!.(
        "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, reason, actor_user_id, occurred_at) VALUES (1, 1, 1, 'removed', 'why', 9, now())"
      )
    end

    assert_raise Postgrex.Error, ~r/finance_attachment_events_reason/, fn ->
      query!.(
        "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, actor_user_id, occurred_at) VALUES (1, 1, 2, 'removed', 9, now())"
      )
    end

    assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
      query!.("DELETE FROM finance_attachment_events")
    end

    assert_raise Postgrex.Error, ~r/only ever lengthened/, fn ->
      query!.(
        "INSERT INTO finance_attachments_retention_changes (tenant_id, company_id, years, reason, changed_by_user_id, changed_at) VALUES (1, 1, 7, 'why', 9, now())"
      )
    end

    %{rows: [[1]]} =
      query!.(
        "INSERT INTO finance_attachments_retention_changes (tenant_id, company_id, years, reason, changed_by_user_id, changed_at) VALUES (1, 1, 10, 'why', 9, now()) RETURNING change_number"
      )
  end
end
