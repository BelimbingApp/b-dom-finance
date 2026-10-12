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

    assert :ok =
             Ecto.Migrator.up(Repo, SchemaContract.migration_version(), TestFixtures.migration(),
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete payables contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
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
end
