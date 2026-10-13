Code.require_file("../priv/repo/migrations/20261012200000_create_finance_einvoice.exs", __DIR__)

Code.require_file(
  "../priv/repo/migrations/20261013090000_add_finance_einvoice_ledger_entry.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261013143000_add_finance_einvoice_posting_uniqueness.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261013221500_add_finance_einvoice_consolidation.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261015150300_claim_finance_einvoice_entries.exs",
  __DIR__
)

Code.require_file(
  "../priv/repo/migrations/20261015150400_add_finance_einvoice_source_links.exs",
  __DIR__
)

defmodule Bilimbi.Finance.Einvoice.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Einvoice.Migrations.{AddConsolidation, AddLedgerEntry, AddSourceLinks}
  alias Bilimbi.Finance.Einvoice.Migrations.{AddPostingUniqueness, ClaimEntries, CreateEinvoice}
  alias Bilimbi.Finance.Einvoice.SchemaContract
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup context do
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

    migrate! = fn migrations ->
      for {version, migration} <- migrations do
        assert :ok = Ecto.Migrator.up(Repo, version, migration, log: false, dynamic_repo: repo)
      end
    end

    [first, second, third, fourth, fifth, sixth] = SchemaContract.migration_versions()

    # The ledger's migrations come first, as in a composed database: the
    # claim migration calls the ledger's claim function.
    {ledger, ledger_later} = Enum.split(LedgerFixtures.migrations(), 3)

    migrate!.(
      ledger ++
        [
          {first, CreateEinvoice},
          {second, AddLedgerEntry},
          {third, AddPostingUniqueness},
          {fourth, AddConsolidation}
        ]
    )

    later = ledger_later ++ [{fifth, ClaimEntries}, {sixth, AddSourceLinks}]
    # One test posts before the ledger recorded owners and migrates itself.
    unless context[:before_claim], do: migrate!.(later)

    %{repo: repo, migrate_later!: fn -> migrate!.(later) end}
  end

  test "the fresh migration implements the complete e-invoicing contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migrations roll back in order", %{repo: repo} do
    [first, second, third, fourth, fifth, sixth] = SchemaContract.migration_versions()

    for {version, migration} <-
          Enum.reverse([
            {first, CreateEinvoice},
            {second, AddLedgerEntry},
            {third, AddPostingUniqueness},
            {fourth, AddConsolidation},
            {fifth, ClaimEntries},
            {sixth, AddSourceLinks}
          ]) do
      assert :ok = Ecto.Migrator.down(Repo, version, migration, log: false, dynamic_repo: repo)
    end

    assert %{rows: [[0]]} =
             SQL.query!(
               repo,
               "SELECT count(*) FROM information_schema.tables WHERE table_name LIKE 'finance_einvoice_%'",
               []
             )
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

    refused = fn sql ->
      try do
        query!.(sql)
      rescue
        error in Postgrex.Error -> error.postgres
      end
    end

    assert %{num_rows: 1} = query!.(event.("posted", 5))
    assert %{num_rows: 1} = query!.(event.("posting_failed", "NULL"))
    assert %{num_rows: 1} = query!.(event.("posting_failed", "NULL"))

    assert %{code: :unique_violation, constraint: "finance_einvoice_status_events_posted_unique"} =
             refused.(event.("posted", 6))

    assert %{num_rows: 1} = query!.(event.("posting_reversed", 7))

    assert %{
             code: :unique_violation,
             constraint: "finance_einvoice_status_events_reversed_unique"
           } = refused.(event.("posting_reversed", 8))

    assert %{rows: [[1], [1]]} =
             query!.(
               "SELECT count(*) FROM finance_einvoice_status_events WHERE event IN ('posted', 'posting_reversed') GROUP BY event"
             )
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

  # The consolidation rules, outside a sandbox: the totals check runs at
  # commit and the "recorded earlier" rule needs an earlier transaction.
  @tag :capture_log
  test "the migration keeps a consolidated document's sources whole and covered once",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    document = fn id, amount ->
      "INSERT INTO finance_einvoice_documents (id, tenant_id, company_id, authority, environment, document_type, code_number, issued_at, currency_code, supplier, buyer, line_extension_amount, tax_exclusive_amount, tax_amount, tax_inclusive_amount, payable_amount, issued_by_user_id, recorded_at) VALUES (#{id}, 1, 1, 'authority', 'sandbox', '01', 'DOC-#{id}', '2026-10-01', 'XTS', '{}', '{}', #{amount}, #{amount}, 0, #{amount}, #{amount}, 1, '2000-01-01')"
    end

    line = fn document_id, amount ->
      "INSERT INTO finance_einvoice_document_lines (tenant_id, company_id, document_id, line_number, description, classification_code, quantity, unit_price, subtotal, line_extension_amount, tax_type, tax_amount) VALUES (1, 1, #{document_id}, 1, 'Item', '004', 1, #{amount}, #{amount}, #{amount}, '06', 0)"
    end

    covers = fn document_id, source_id ->
      "INSERT INTO finance_einvoice_consolidated_sources (tenant_id, company_id, document_id, source_document_id, line_number) VALUES (1, 1, #{document_id}, #{source_id}, 1)"
    end

    event = fn document_id, name ->
      "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, recorded_at) VALUES (1, 1, #{document_id}, 99, '#{name}', 'user', 1, '2000-01-01')"
    end

    consolidated = fn id, amount, sources ->
      [document.(id, amount), line.(id, amount)] ++ Enum.map(sources, &covers.(id, &1))
    end

    submission =
      fn document_id ->
        "INSERT INTO finance_einvoice_submissions (tenant_id, company_id, document_id, environment, format, document_version, payload, payload_sha256, actor_type, actor_user_id, recorded_at) VALUES (1, 1, #{document_id}, 'sandbox', 'JSON', '1.0', 'x', encode(sha256('x'), 'hex'), 'user', 1, now())"
      end

    assert {:ok, _} =
             in_transaction.([document.(1, 10), line.(1, 10), document.(2, 5), line.(2, 5)])

    assert {:ok, _} = in_transaction.(consolidated.(10, 15, [1, 2]))

    assert_raise Postgrex.Error, ~r/already recorded/, fn ->
      in_transaction.([document.(3, 1), line.(3, 1), covers.(10, 3)])
    end

    assert_raise Postgrex.Error, ~r/totals differ from its sources/, fn ->
      in_transaction.([document.(4, 7), line.(4, 7) | consolidated.(11, 6, [4])])
    end

    assert_raise Postgrex.Error, ~r/is already consolidated/, fn ->
      in_transaction.(consolidated.(12, 10, [1]))
    end

    assert_raise Postgrex.Error, ~r/never a source/, fn ->
      in_transaction.(consolidated.(13, 15, [10]))
    end

    assert_raise Postgrex.Error, ~r/cannot be submitted on its own/, fn ->
      query!.(submission.(1))
    end

    # A cancelled consolidated document releases its sources and is never
    # submitted again.
    assert {:ok, _} = in_transaction.([event.(10, "cancelled")])
    assert {:ok, _} = in_transaction.(consolidated.(14, 10, [1]))
    assert %{num_rows: 1} = query!.(submission.(2))

    assert_raise Postgrex.Error, ~r/released its sources/, fn -> query!.(submission.(10)) end

    assert_raise Postgrex.Error, ~r/submitted on its own and cannot be consolidated/, fn ->
      in_transaction.(consolidated.(15, 5, [2]))
    end

    for sql <- [
          "UPDATE finance_einvoice_consolidated_sources SET company_id = company_id",
          "DELETE FROM finance_einvoice_consolidated_sources",
          "TRUNCATE finance_einvoice_consolidated_sources"
        ] do
      assert_raise Postgrex.Error, ~r/finance e-invoicing keeps/, fn -> query!.(sql) end
    end

    assert %{rows: [[10, 1], [10, 2], [14, 1]]} =
             query!.(
               "SELECT document_id, source_document_id FROM finance_einvoice_consolidated_sources ORDER BY document_id, source_document_id"
             )
  end

  @document "INSERT INTO finance_einvoice_documents (id, tenant_id, company_id, authority, environment, document_type, code_number, issued_at, currency_code, supplier, buyer, line_extension_amount, tax_exclusive_amount, tax_amount, tax_inclusive_amount, payable_amount, issued_by_user_id, recorded_at) VALUES (ID, 1, 1, 'authority', 'sandbox', '01', 'INV-ID', '2026-10-01', 'XTS', '{}', '{}', 10, 10, 0, 10, 10, 1, '2000-01-01')"
  @line "INSERT INTO finance_einvoice_document_lines (tenant_id, company_id, document_id, line_number, description, classification_code, quantity, unit_price, subtotal, line_extension_amount, tax_type, tax_amount) VALUES (1, 1, ID, 1, 'Item', '022', 1, 10, 10, 10, '06', 0)"

  # Entries this module posted before the ledger recorded owners are
  # claimed by the migration, through the ledger's own function.
  @tag :before_claim
  @tag :capture_log
  test "the claim migration marks the module's earlier entries as its own",
       %{repo: repo, migrate_later!: migrate_later!} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    entry = fn id, reverses ->
      [
        "INSERT INTO finance_ledger_entries (id, tenant_id, company_id, entry_number, entry_date, description, currency_code, reverses_entry_id, posted_by_user_id, posted_at) VALUES (#{id}, 1, 1, 1, '2026-10-01', 'Entry', 'XTS', #{reverses || "NULL"}, 1, now())",
        "INSERT INTO finance_ledger_entry_lines (tenant_id, company_id, entry_id, line_number, account_id, debit, credit) VALUES (1, 1, #{id}, 1, 1, 10, 0), (1, 1, #{id}, 2, 2, 0, 10)"
      ]
    end

    event = fn document, name, entry ->
      "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, ledger_entry_id, recorded_at) VALUES (1, 1, #{document}, 99, '#{name}', 'user', 1, #{entry}, '2000-01-01')"
    end

    {:ok, _} =
      in_transaction.(
        [
          "INSERT INTO finance_ledger_books (tenant_id, company_id, currency_code, minor_units, inserted_at) VALUES (1, 1, 'XTS', 2, now())",
          "INSERT INTO finance_ledger_accounts (id, tenant_id, company_id, code, name, account_type, inserted_at, updated_at) VALUES (1, 1, 1, '1', 'Debit', 'asset', now(), now()), (2, 1, 1, '2', 'Credit', 'income', now(), now())"
        ] ++
          entry.(1, nil) ++
          entry.(2, 1) ++
          entry.(3, nil) ++
          [
            String.replace(@document, "ID", "1"),
            String.replace(@line, "ID", "1"),
            event.(1, "issued", "NULL"),
            event.(1, "posted", 1),
            event.(1, "posting_reversed", 2)
          ]
      )

    migrate_later!.()

    assert %{
             rows: [
               [1, true, "finance/einvoice", "document:1"],
               [2, true, "finance/einvoice", "document:1"],
               [3, true, nil, nil]
             ]
           } =
             query!.(
               "SELECT id, legacy, owner_module, owner_record FROM finance_ledger_entries ORDER BY id"
             )
  end

  @tag :capture_log
  test "a source has one standing document, and a linked document stands only while it does",
       %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    document = fn id ->
      [String.replace(@document, "ID", "#{id}"), String.replace(@line, "ID", "#{id}")]
    end

    link = fn document, record ->
      "INSERT INTO finance_einvoice_source_links (tenant_id, company_id, document_id, source_module, source_record, ledger_entry_id) VALUES (1, 1, #{document}, 'finance/receivables', '#{record}', 7)"
    end

    event = fn document, name ->
      "INSERT INTO finance_einvoice_status_events (tenant_id, company_id, document_id, sequence, event, actor_type, actor_user_id, recorded_at) VALUES (1, 1, #{document}, 99, '#{name}', 'user', 1, '2000-01-01')"
    end

    submission = fn document ->
      "INSERT INTO finance_einvoice_submissions (tenant_id, company_id, document_id, environment, format, document_version, payload, payload_sha256, actor_type, actor_user_id, recorded_at) VALUES (1, 1, #{document}, 'sandbox', 'JSON', '1.0', 'x', encode(sha256('x'), 'hex'), 'user', 1, '2000-01-01')"
    end

    # A link is written with its document, once per source.
    assert {:ok, _} =
             in_transaction.(document.(1) ++ [link.(1, "document:5"), event.(1, "issued")])

    assert_raise Postgrex.Error, ~r/already recorded/, fn ->
      in_transaction.([link.(1, "document:6")])
    end

    # An issued, unsubmitted document does not stand: another may link the
    # source, and then the first is not submitted.
    assert {:ok, _} =
             in_transaction.(document.(2) ++ [link.(2, "document:5"), event.(2, "issued")])

    assert {:ok, _} = in_transaction.([submission.(2), event.(2, "submitted")])

    assert_raise Postgrex.Error,
                 ~r/document 1 is not submitted: .* source of document 2, which stands/,
                 fn ->
                   in_transaction.([submission.(1)])
                 end

    assert_raise Postgrex.Error, ~r/source of document 2, which stands/, fn ->
      in_transaction.(document.(3) ++ [link.(3, "document:5"), event.(3, "issued")])
    end

    # Once the authority refuses it, the source is free again.
    assert {:ok, _} = in_transaction.([event.(2, "refused")])

    assert {:ok, _} =
             in_transaction.(document.(3) ++ [link.(3, "document:5"), event.(3, "issued")])

    assert {:ok, _} = in_transaction.([submission.(3), event.(3, "submitted")])

    # A consolidated document carries its source's link and may be submitted.
    assert {:ok, _} =
             in_transaction.(document.(4) ++ [link.(4, "document:8"), event.(4, "issued")])

    assert {:ok, _} =
             in_transaction.(
               document.(5) ++
                 [
                   "INSERT INTO finance_einvoice_consolidated_sources (tenant_id, company_id, document_id, source_document_id, line_number) VALUES (1, 1, 5, 4, 1)",
                   event.(4, "consolidated"),
                   link.(5, "document:8"),
                   event.(5, "issued")
                 ]
             )

    assert {:ok, _} = in_transaction.([submission.(5), event.(5, "submitted")])

    # Links are append-only.
    for sql <- [
          "UPDATE finance_einvoice_source_links SET ledger_entry_id = 9",
          "DELETE FROM finance_einvoice_source_links",
          "TRUNCATE finance_einvoice_source_links"
        ] do
      assert_raise Postgrex.Error, ~r/finance e-invoicing keeps/, fn -> query!.(sql) end
    end
  end
end
