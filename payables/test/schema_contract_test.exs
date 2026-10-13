defmodule Bilimbi.Finance.Payables.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Payables.SchemaContract
  alias Bilimbi.Finance.Payables.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_payables_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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

  test "the fresh migrations implement the complete payables contract", %{repo: repo} do
    assert Enum.map(TestFixtures.migrations(), &elem(&1, 0)) ==
             SchemaContract.migration_versions()

    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migrations roll back in order", %{repo: repo} do
    for {version, module} <- Enum.reverse(TestFixtures.migrations()) do
      assert :ok = Ecto.Migrator.down(Repo, version, module, log: false, dynamic_repo: repo)
    end

    assert %{rows: [[0]]} =
             SQL.query!(
               repo,
               "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'finance_payables_%'",
               []
             )
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred checks run at commit and a later transaction is a
  # different one. A refused commit disconnects, which Postgrex logs; the log
  # is expected.
  @tag :capture_log
  test "the migration's triggers keep documents whole, numbered, and moving forward",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_payables_tax_codes (id, tenant_id, company_id, code, name, rate, account_id, inserted_at, updated_at) VALUES (1, 1, 1, 'T', 'Tax', 10, 9, now(), now())"
      ])

    # The writer's own status time is replaced by the database's.
    document = fn id, net, tax ->
      "INSERT INTO finance_payables_documents (id, tenant_id, company_id, document_type, status, party_key, party_name, party_document_number, document_date, due_date, currency_code, total_net, total_tax, total, created_by_user_id, created_at) VALUES (#{id}, 1, 1, 'bill', 'draft', 'P', 'Party', 'D-#{id}', '2026-10-01', '2026-10-01', 'XTS', #{net}, #{tax}, #{net + tax}, 1, '2000-01-01')"
    end

    line = fn document_id, number, amount, tax_code ->
      "INSERT INTO finance_payables_document_lines (tenant_id, company_id, document_id, line_number, description, account_id, amount, tax_code_id) VALUES (1, 1, #{document_id}, #{number}, 'Line', 5, #{amount}, #{tax_code})"
    end

    tax_line = fn document_id, taxable, tax ->
      "INSERT INTO finance_payables_document_tax_lines (tenant_id, company_id, document_id, line_number, tax_code_id, tax_code, rate, account_id, taxable_amount, tax_amount) VALUES (1, 1, #{document_id}, 1, 1, 'T', 10, 9, #{taxable}, #{tax})"
    end

    assert {:ok, _} =
             in_transaction.([
               document.(1, 30, 2),
               line.(1, 1, 20, 1),
               line.(1, 2, 10, "NULL"),
               tax_line.(1, 20, 2)
             ])

    assert {:ok, _} = in_transaction.([document.(2, 5, 0), line.(2, 1, 5, "NULL")])

    assert_raise Postgrex.Error, ~r/totals differ from its lines/, fn ->
      in_transaction.([document.(3, 10, 0), line.(3, 1, 9, "NULL")])
    end

    assert_raise Postgrex.Error, ~r/has no lines/, fn -> in_transaction.([document.(4, 1, 0)]) end

    assert_raise Postgrex.Error, ~r/tax lines differ from its lines/, fn ->
      in_transaction.([document.(5, 10, 1), line.(5, 1, 10, "NULL"), tax_line.(5, 10, 1)])
    end

    # A draft recorded in an earlier transaction takes no more lines.
    assert_raise Postgrex.Error, ~r/already recorded: a line cannot be added/, fn ->
      in_transaction.([line.(2, 2, 1, "NULL")])
    end

    move = fn id, set -> "UPDATE finance_payables_documents SET #{set} WHERE id = #{id}" end
    approve = &move.(&1, "status = 'approved', approved_by_user_id = 1")

    post =
      &move.(
        &1,
        "status = 'posted', posted_by_user_id = 1, payable_account_id = 7, entry_id = #{&1}, entry_number = #{&1}, document_number = 99"
      )

    assert {:ok, _} = in_transaction.([approve.(1), post.(1)])

    assert {:ok, _} =
             in_transaction.([
               move.(2, "status = 'voided', voided_by_user_id = 1, void_reason = 'x'")
             ])

    assert {:ok, _} =
             in_transaction.([
               document.(6, 1, 0),
               line.(6, 1, 1, "NULL"),
               approve.(6),
               post.(6)
             ])

    for {sql, message} <- [
          {move.(1, "status = 'voided', voided_by_user_id = 1, void_reason = 'x'"),
           ~r/cannot go from posted to voided/},
          {move.(2, "status = 'draft', voided_by_user_id = NULL"),
           ~r/cannot go from voided to draft/},
          {"DELETE FROM finance_payables_documents WHERE id = 2", ~r/finance payables keeps/},
          {"UPDATE finance_payables_document_lines SET amount = 1", ~r/finance payables keeps/},
          {"TRUNCATE finance_payables_document_lines", ~r/finance payables keeps/},
          {"DELETE FROM finance_payables_tax_codes", ~r/finance payables keeps/},
          {"UPDATE finance_payables_tax_codes SET code = 'X'", ~r/company and code/}
        ] do
      assert_raise Postgrex.Error, message, fn -> query!.(sql) end
    end

    # Refused and voided documents took no number; the stamps are the database's.
    assert %{rows: [[1, "posted", 1, true], [2, "voided", nil, true], [6, "posted", 2, true]]} =
             query!.(
               "SELECT id, status, document_number, created_at > '2026-01-01' AND (approved_at IS NULL OR approved_at >= created_at) FROM finance_payables_documents ORDER BY id"
             )
  end

  # Each rule about a later transaction, which the sandbox cannot show.
  @tag :capture_log
  test "the migrations' triggers keep a match record whole and a held bill held", %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_payables_documents (id, tenant_id, company_id, document_type, status, party_key, party_name, party_document_number, document_date, due_date, currency_code, total_net, total_tax, total, created_by_user_id) VALUES (1, 1, 1, 'bill', 'draft', 'P', 'Party', 'D-1', '2026-10-01', '2026-10-01', 'XTS', 50, 0, 50, 1)",
        "INSERT INTO finance_payables_document_lines (tenant_id, company_id, document_id, line_number, description, account_id, amount, order_line_id, quantity) VALUES (1, 1, 1, 1, 'Line', 5, 50, 7, 10)",
        "UPDATE finance_payables_documents SET status = 'approved', approved_by_user_id = 1 WHERE id = 1"
      ])

    event = fn id, event, reason, held ->
      "INSERT INTO finance_payables_match_events (id, tenant_id, company_id, document_id, event, reason, held_event_id, actor_user_id, occurred_at) VALUES (#{id}, 1, 1, 1, '#{event}', #{reason}, #{held}, 1, '2000-01-01')"
    end

    match_line = fn id, event_id ->
      "INSERT INTO finance_payables_match_lines (id, tenant_id, company_id, event_id, document_id, line_number, order_line_id, billed_quantity, billed_unit_price, previously_billed_quantity) VALUES (#{id}, 1, 1, #{event_id}, 1, 1, 7, 10, 5, 0)"
    end

    exception = fn line_id ->
      "INSERT INTO finance_payables_match_exceptions (tenant_id, company_id, match_line_id, code, detail) VALUES (1, 1, #{line_id}, 'price_differs', 'x')"
    end

    post =
      "UPDATE finance_payables_documents SET status = 'posted', posted_by_user_id = 1, payable_account_id = 7, entry_id = 1, entry_number = 1 WHERE id = 1"

    # A hold, recorded whole and stamped by the database.
    assert {:ok, _} =
             in_transaction.([
               event.(1, "held", "NULL", "NULL"),
               match_line.(1, 1),
               exception.(1),
               "UPDATE finance_payables_documents SET status = 'held' WHERE id = 1"
             ])

    assert %{rows: [[true]]} =
             query!.("SELECT occurred_at > '2026-01-01' FROM finance_payables_match_events")

    assert_raise Postgrex.Error, ~r/complete when recorded/, fn ->
      in_transaction.([match_line.(2, 1)])
    end

    assert_raise Postgrex.Error, ~r/complete when recorded/, fn ->
      in_transaction.([exception.(1)])
    end

    # Held, with exceptions again and no approval: not posted.
    assert_raise Postgrex.Error, ~r/match exceptions are not approved/, fn ->
      in_transaction.([
        event.(2, "posted", "NULL", "NULL"),
        match_line.(3, 2),
        exception.(3),
        post
      ])
    end

    assert_raise Postgrex.Error, ~r/no held match exception to approve/, fn ->
      in_transaction.([
        "UPDATE finance_payables_documents SET status = 'voided', voided_by_user_id = 1, void_reason = 'x' WHERE id = 1",
        event.(3, "exception_approved", "'x'", "1")
      ])
    end

    assert_raise Postgrex.Error, ~r/finance_payables_match_events_reason/, fn ->
      in_transaction.([event.(3, "exception_approved", "NULL", "1")])
    end

    assert_raise Postgrex.Error, ~r/must name its latest hold/, fn ->
      in_transaction.([event.(3, "exception_approved", "'agreed'", "NULL")])
    end

    assert_raise Postgrex.Error, ~r/must name its latest hold/, fn ->
      in_transaction.([event.(3, "exception_approved", "'agreed'", "99")])
    end

    assert_raise Postgrex.Error, ~r/finance_payables_match_events_held_event"/, fn ->
      in_transaction.([event.(3, "held", "NULL", "1")])
    end

    assert {:ok, _} = in_transaction.([event.(3, "exception_approved", "'agreed'", "1")])

    assert_raise Postgrex.Error, ~r/no held match exception to approve/, fn ->
      in_transaction.([event.(4, "exception_approved", "'again'", "1")])
    end

    # Approved: posts with its match record, over the same exception.
    assert {:ok, _} =
             in_transaction.([
               event.(4, "posted", "NULL", "NULL"),
               match_line.(4, 4),
               exception.(4),
               post
             ])

    assert %{rows: [["posted", 1]]} =
             query!.(
               "SELECT status, document_number FROM finance_payables_documents WHERE id = 1"
             )

    for sql <- [
          "UPDATE finance_payables_match_events SET reason = 'y'",
          "DELETE FROM finance_payables_match_lines",
          "TRUNCATE finance_payables_match_exceptions"
        ] do
      assert_raise Postgrex.Error, ~r/finance payables keeps/, fn -> query!.(sql) end
    end
  end

  test "the migration's triggers stamp and keep the change history", %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    {:ok, _} =
      Repo.transaction(fn ->
        query!.(
          "INSERT INTO finance_payables_settings_changes (tenant_id, company_id, new_payable_account_id, changed_by_user_id, changed_at) VALUES (1, 1, 7, 1, '2000-01-01')"
        )

        query!.(
          "INSERT INTO finance_payables_tax_codes (id, tenant_id, company_id, code, name, rate, account_id, inserted_at, updated_at) VALUES (1, 1, 1, 'T', 'Tax', 10, 9, now(), now())"
        )

        query!.(
          "INSERT INTO finance_payables_tax_code_changes (tenant_id, company_id, tax_code_id, new_name, new_rate, new_account_id, new_active, changed_by_user_id, changed_at) VALUES (1, 1, 1, 'Tax', 10, 9, true, 1, '2000-01-01')"
        )
      end)

    assert %{rows: [[true], [true]]} =
             query!.(
               "(SELECT changed_at > '2026-01-01' FROM finance_payables_settings_changes) UNION ALL (SELECT changed_at > '2026-01-01' FROM finance_payables_tax_code_changes)"
             )

    for sql <- [
          "UPDATE finance_payables_settings_changes SET reason = 'x'",
          "DELETE FROM finance_payables_settings_changes",
          "TRUNCATE finance_payables_settings_changes",
          "UPDATE finance_payables_tax_code_changes SET reason = 'x'",
          "DELETE FROM finance_payables_tax_code_changes",
          "TRUNCATE finance_payables_tax_code_changes"
        ] do
      assert_raise Postgrex.Error, ~r/finance payables keeps/, fn -> query!.(sql) end
    end

    assert_raise Postgrex.Error, ~r/finance_payables_tax_code_changes_before/, fn ->
      query!.(
        "INSERT INTO finance_payables_tax_code_changes (tenant_id, company_id, tax_code_id, old_name, new_name, new_rate, new_account_id, new_active, changed_by_user_id) VALUES (1, 1, 1, 'Tax', 'Tax', 10, 9, true, 1)"
      )
    end
  end

  @tag :capture_log
  test "the migration's triggers keep payments allocated, numbered, and append-only",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_payables_documents (id, tenant_id, company_id, document_type, status, party_key, party_name, party_document_number, document_date, due_date, currency_code, total_net, total_tax, total, created_by_user_id) VALUES (1, 1, 1, 'bill', 'draft', 'P', 'Party', 'D-1', '2026-10-01', '2026-10-01', 'XTS', 50, 0, 50, 1)",
        "INSERT INTO finance_payables_document_lines (tenant_id, company_id, document_id, line_number, description, account_id, amount) VALUES (1, 1, 1, 1, 'Line', 5, 50)"
      ])

    payment = fn id, amount, reverses ->
      "INSERT INTO finance_payables_payments (id, tenant_id, company_id, payment_number, payment_date, party_key, party_name, paid_from_account_id, amount, currency_code, reverses_payment_id, entry_id, entry_number, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 99, '2026-10-05', 'P', 'Party', 3, #{amount}, 'XTS', #{reverses}, #{id}, #{id}, 1, '2000-01-01')"
    end

    allocation = fn payment_id, number, amount ->
      "INSERT INTO finance_payables_payment_allocations (tenant_id, company_id, payment_id, line_number, document_id, amount) VALUES (1, 1, #{payment_id}, #{number}, 1, #{amount})"
    end

    assert {:ok, _} = in_transaction.([payment.(1, 20, "NULL"), allocation.(1, 1, 20)])

    assert_raise Postgrex.Error, ~r/allocations differ from its amount/, fn ->
      in_transaction.([payment.(2, 20, "NULL"), allocation.(2, 1, 19)])
    end

    assert_raise Postgrex.Error, ~r/already posted: an allocation cannot be added/, fn ->
      in_transaction.([allocation.(1, 2, 1)])
    end

    assert_raise Postgrex.Error, ~r/takes no allocations/, fn ->
      in_transaction.([payment.(3, 20, 1), allocation.(3, 1, 20)])
    end

    assert {:ok, _} = in_transaction.([payment.(4, 20, 1)])

    for sql <- [
          "UPDATE finance_payables_payments SET amount = 1",
          "DELETE FROM finance_payables_payment_allocations",
          "TRUNCATE finance_payables_payments CASCADE"
        ] do
      assert_raise Postgrex.Error, ~r/finance payables keeps/, fn -> query!.(sql) end
    end

    # Refused transactions consumed no number: the two posted payments are 1 and 2.
    assert %{rows: [[1, 1, true], [4, 2, true]]} =
             query!.(
               "SELECT id, payment_number, posted_at > '2026-01-01' FROM finance_payables_payments ORDER BY id"
             )
  end

  @tag :capture_log
  test "the migration's triggers keep payment requests allocated, numbered, and decided once",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO finance_payables_documents (id, tenant_id, company_id, document_type, status, party_key, party_name, party_document_number, document_date, due_date, currency_code, total_net, total_tax, total, created_by_user_id) VALUES (1, 1, 1, 'bill', 'draft', 'P', 'Party', 'D-1', '2026-10-01', '2026-10-01', 'XTS', 50, 0, 50, 1)",
        "INSERT INTO finance_payables_document_lines (tenant_id, company_id, document_id, line_number, description, account_id, amount) VALUES (1, 1, 1, 1, 'Line', 5, 50)"
      ])

    # The writer's own number and time are replaced by the database's.
    request = fn id, amount ->
      "INSERT INTO finance_payables_payment_requests (id, tenant_id, company_id, request_number, payment_date, party_key, party_name, paid_from_account_id, amount, currency_code, submitted_by_user_id, submitted_at) VALUES (#{id}, 1, 1, 99, '2026-10-05', 'P', 'Party', 3, #{amount}, 'XTS', 1, '2000-01-01')"
    end

    allocation = fn request_id, number, amount ->
      "INSERT INTO finance_payables_payment_request_allocations (tenant_id, company_id, request_id, line_number, document_id, amount) VALUES (1, 1, #{request_id}, #{number}, 1, #{amount})"
    end

    payment = fn id, amount ->
      [
        "INSERT INTO finance_payables_payments (id, tenant_id, company_id, payment_number, payment_date, party_key, party_name, paid_from_account_id, amount, currency_code, entry_id, entry_number, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 99, '2026-10-05', 'P', 'Party', 3, #{amount}, 'XTS', #{id}, #{id}, 2, now())",
        "INSERT INTO finance_payables_payment_allocations (tenant_id, company_id, payment_id, line_number, document_id, amount) VALUES (1, 1, #{id}, 1, 1, #{amount})"
      ]
    end

    event = fn request_id, payment_id ->
      "INSERT INTO finance_payables_payment_request_events (tenant_id, company_id, request_id, event, payment_id, actor_user_id, occurred_at) VALUES (1, 1, #{request_id}, 'posted', #{payment_id}, 2, '2000-01-01')"
    end

    assert {:ok, _} = in_transaction.([request.(1, 20), allocation.(1, 1, 20)])

    assert_raise Postgrex.Error, ~r/request 2 allocations differ from its amount/, fn ->
      in_transaction.([request.(2, 20), allocation.(2, 1, 19)])
    end

    assert_raise Postgrex.Error, ~r/request 3 allocations differ from its amount/, fn ->
      in_transaction.([request.(3, 20)])
    end

    assert_raise Postgrex.Error, ~r/already submitted: an allocation cannot be added/, fn ->
      in_transaction.([allocation.(1, 2, 1)])
    end

    assert_raise Postgrex.Error, ~r/posted only by a payment of what it requested/, fn ->
      in_transaction.(payment.(1, 19) ++ [event.(1, 1)])
    end

    assert {:ok, _} = in_transaction.(payment.(2, 20) ++ [event.(1, 2)])

    assert_raise Postgrex.Error, ~r/finance_payables_payment_request_events_request_unique/, fn ->
      in_transaction.([
        "INSERT INTO finance_payables_payment_request_events (tenant_id, company_id, request_id, event, reason, actor_user_id, occurred_at) VALUES (1, 1, 1, 'rejected', 'Late', 2, now())"
      ])
    end

    for sql <- [
          "UPDATE finance_payables_payment_requests SET amount = 1",
          "DELETE FROM finance_payables_payment_request_allocations",
          "DELETE FROM finance_payables_payment_request_events",
          "TRUNCATE finance_payables_payment_requests CASCADE"
        ] do
      assert_raise Postgrex.Error, ~r/finance payables keeps/, fn -> query!.(sql) end
    end

    assert %{rows: [[1, true]]} =
             query!.(
               "SELECT request_number, submitted_at > '2026-01-01' FROM finance_payables_payment_requests"
             )

    assert %{rows: [[true]]} =
             query!.(
               "SELECT occurred_at > '2026-01-01' FROM finance_payables_payment_request_events"
             )
  end
end
