Code.require_file("../priv/repo/migrations/20261012200000_create_finance_einvoice.exs", __DIR__)

Code.require_file(
  "../priv/repo/migrations/20261013090000_add_finance_einvoice_ledger_entry.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261013143000_add_finance_einvoice_posting_uniqueness.exs",
  __DIR__
)

defmodule Bilimbi.Finance.Einvoice.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Einvoice.Migrations.{AddLedgerEntry, AddPostingUniqueness, CreateEinvoice}
  alias Bilimbi.Finance.Einvoice.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_finance_einvoice_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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

    [first, second, third] = SchemaContract.migration_versions()

    for {version, migration} <- [
          {first, CreateEinvoice},
          {second, AddLedgerEntry},
          {third, AddPostingUniqueness}
        ] do
      assert :ok = Ecto.Migrator.up(Repo, version, migration, log: false, dynamic_repo: repo)
    end

    %{repo: repo}
  end

  test "the fresh migration implements the complete e-invoicing contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the database refuses a second posted or posting_reversed event for a document",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    Repo.transaction(fn ->
      query!.(
        "INSERT INTO finance_einvoice_documents (id, tenant_id, company_id, authority, environment, document_type, code_number, issued_at, currency_code, supplier, buyer, line_extension_amount, tax_exclusive_amount, tax_amount, tax_inclusive_amount, payable_amount, issued_by_user_id, recorded_at) VALUES (1, 1, 1, 'authority', 'sandbox', '01', 'INV-1', '2026-10-01', 'XTS', '{}', '{}', 10, 10, 0, 10, 10, 1, '2000-01-01')"
      )

      query!.(
        "INSERT INTO finance_einvoice_document_lines (tenant_id, company_id, document_id, line_number, description, classification_code, quantity, unit_price, subtotal, line_extension_amount, tax_type, tax_amount) VALUES (1, 1, 1, 1, 'Item', '022', 1, 10, 10, 10, '06', 0)"
      )
    end)

    event = fn name, entry ->
      "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, ledger_entry_id, recorded_at) VALUES (1, 1, 1, 99, '#{name}', 'user', 1, #{entry}, '2000-01-01')"
    end

    assert %{num_rows: 1} = query!.(event.("posted", 5))
    assert %{num_rows: 1} = query!.(event.("posting_failed", "NULL"))
    assert %{num_rows: 1} = query!.(event.("posting_failed", "NULL"))

    assert_raise Postgrex.Error, ~r/finance_einvoice_status_events_posted_unique/, fn ->
      query!.(event.("posted", 6))
    end

    assert %{num_rows: 1} = query!.(event.("posting_reversed", 7))

    assert_raise Postgrex.Error, ~r/finance_einvoice_status_events_reversed_unique/, fn ->
      query!.(event.("posting_reversed", 8))
    end
  end

  @tag :capture_log
  test "two sessions racing to record an event cannot both take the same sequence",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    Repo.transaction(fn ->
      query!.(
        "INSERT INTO finance_einvoice_documents (id, tenant_id, company_id, authority, environment, document_type, code_number, issued_at, currency_code, supplier, buyer, line_extension_amount, tax_exclusive_amount, tax_amount, tax_inclusive_amount, payable_amount, issued_by_user_id, recorded_at) VALUES (1, 1, 1, 'authority', 'sandbox', '01', 'INV-1', '2026-10-01', 'XTS', '{}', '{}', 10, 10, 0, 10, 10, 1, '2000-01-01')"
      )

      query!.(
        "INSERT INTO finance_einvoice_document_lines (tenant_id, company_id, document_id, line_number, description, classification_code, quantity, unit_price, subtotal, line_extension_amount, tax_type, tax_amount) VALUES (1, 1, 1, 1, 'Item', '022', 1, 10, 10, 10, '06', 0)"
      )
    end)

    posted =
      "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, ledger_entry_id, recorded_at) VALUES (1, 1, 1, 99, 'posted', 'user', 1, 5, '2000-01-01')"

    results =
      for _session <- 1..2 do
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          try do
            Repo.transaction(fn ->
              query!.(posted)
              Process.sleep(300)
            end)
          rescue
            error in Postgrex.Error -> {:error, error}
          end
        end)
      end
      |> Task.await_many()

    assert [{:ok, _}, {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}] =
             Enum.sort_by(results, &match?({:error, _}, &1))

    assert %{rows: [[1]]} = query!.("SELECT count(*) FROM finance_einvoice_status_events")
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred totals check runs at commit. A refused commit
  # disconnects, which Postgrex logs; the log is expected.
  @tag :capture_log
  test "the migration's triggers keep records whole, stamped, numbered, and append-only",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    # The writer's own recording time is replaced by the database's.
    document = fn id, amount ->
      "INSERT INTO finance_einvoice_documents (id, tenant_id, company_id, authority, environment, document_type, code_number, issued_at, currency_code, supplier, buyer, line_extension_amount, tax_exclusive_amount, tax_amount, tax_inclusive_amount, payable_amount, issued_by_user_id, recorded_at) VALUES (#{id}, 1, 1, 'authority', 'sandbox', '01', 'INV-#{id}', '2026-10-01', 'XTS', '{}', '{}', #{amount}, #{amount}, 0, #{amount}, #{amount}, 1, '2000-01-01')"
    end

    line = fn document_id, number, amount ->
      "INSERT INTO finance_einvoice_document_lines (tenant_id, company_id, document_id, line_number, description, classification_code, quantity, unit_price, subtotal, line_extension_amount, tax_type, tax_amount) VALUES (1, 1, #{document_id}, #{number}, 'Item', '022', 1, #{amount}, #{amount}, #{amount}, '06', 0)"
    end

    event = fn document_id, name ->
      "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, recorded_at) VALUES (1, 1, #{document_id}, 99, '#{name}', 'user', 1, '2000-01-01')"
    end

    assert {:ok, _} =
             in_transaction.([
               document.(1, 10),
               line.(1, 1, 4),
               line.(1, 2, 6),
               event.(1, "issued")
             ])

    assert_raise Postgrex.Error, ~r/totals differ from its lines/, fn ->
      in_transaction.([document.(2, 10), line.(2, 1, 9)])
    end

    assert_raise Postgrex.Error, ~r/has no lines/, fn -> in_transaction.([document.(3, 0)]) end

    assert_raise Postgrex.Error, ~r/already recorded/, fn -> in_transaction.([line.(1, 3, 1)]) end

    # A cancellation is a new event, numbered after the last, and a posting
    # names a positive ledger entry.
    assert {:ok, _} = in_transaction.([event.(1, "cancelled")])

    assert_raise Postgrex.Error, ~r/ledger_entry_id/, fn ->
      query!.(
        "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, ledger_entry_id, recorded_at) VALUES (1, 1, 1, 99, 'posted', 'user', 1, 0, '2000-01-01')"
      )
    end

    payload = "convert_to('{\"Invoice\":[]}', 'UTF8')"

    submission = fn hash ->
      "INSERT INTO finance_einvoice_submissions (tenant_id, company_id, document_id, environment, format, document_version, payload, payload_sha256, actor_type, system_principal, recorded_at) VALUES (1, 1, 1, 'sandbox', 'JSON', '1.1', #{payload}, #{hash}, 'system', 'finance.einvoice.submitter', now())"
    end

    assert_raise Postgrex.Error, ~r/payload_sha256/, fn ->
      query!.(submission.("repeat('0', 64)"))
    end

    assert %{num_rows: 1} = query!.(submission.("encode(sha256(#{payload}), 'hex')"))

    for table <- [
          "finance_einvoice_documents",
          "finance_einvoice_document_lines",
          "finance_einvoice_submissions",
          "finance_einvoice_status_events"
        ],
        sql <- [
          "UPDATE #{table} SET company_id = company_id",
          "DELETE FROM #{table}",
          "TRUNCATE #{table} CASCADE"
        ] do
      assert_raise Postgrex.Error, ~r/finance e-invoicing keeps/, fn -> query!.(sql) end
    end

    assert %{rows: [[1, "issued", true], [2, "cancelled", true]]} =
             query!.(
               "SELECT sequence, event, recorded_at > '2026-01-01' FROM finance_einvoice_status_events ORDER BY sequence"
             )

    assert %{rows: [[true]]} =
             query!.("SELECT recorded_at > '2026-01-01' FROM finance_einvoice_documents")
  end
end
