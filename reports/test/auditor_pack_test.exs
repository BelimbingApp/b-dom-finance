defmodule Bilimbi.Finance.Reports.AuditorPackTest do
  use Bilimbi.Finance.Reports.IssuedCase, async: false
  alias Bilimbi.Base.{Settings, Audit}
  alias Bilimbi.Finance.Reports.Serialization

  setup do
    root = Path.join(System.tmp_dir!(), "finance-pack-artifacts-#{Ecto.UUID.generate()}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, _} = Settings.put("artifacts.storage_root", root)
    assert {:ok, _} = Settings.put("artifacts.retention_days", 30)
    :ok
  end

  test "exports every GL page and verifies hashes, row counts, exact amounts and text defense",
       context do
    %{operator: operator, accounts: accounts} = context

    assert {:ok, _} =
             Ledger.update_account(operator, 73, accounts["1010"].id, %{
               name: "=HYPERLINK(\"untrusted\")"
             })

    for _ <- 1..501 do
      TestFixtures.post!(operator, accounts, ~D[2026-10-01], [
        {"1010", :debit, "1.23"},
        {"3000", :credit, "1.23"}
      ])
    end

    assert {:ok, artifact} = Reports.export_auditor_pack(operator, 73, ~D[2026-10-31])
    assert artifact.content_type == "application/zip"

    reader =
      Ledger.TestFixtures.sign_in!(
        context.first_scope,
        73,
        95,
        ~w(finance.ledger.view finance.receivables.view finance.payables.view finance.reconciliation.view finance.einvoice.view finance.payroll.view finance.sst.view finance.fixed-assets.view finance.reports.reports-export)
      )

    assert {:ok, reader_artifact} = Reports.export_auditor_pack(reader, 73, ~D[2026-10-31])
    assert {:ok, _} = Reports.read_auditor_pack(reader, 73, reader_artifact.id)

    assert {:error, :unauthorized} =
             Ledger.post_entry(reader, 73, %{entry_date: ~D[2026-10-01], lines: []})

    assert {:ok, %{bytes: bytes}} = Reports.read_auditor_pack(operator, 73, artifact.id)
    assert {:ok, extracted} = :zip.extract(bytes, [:memory])
    files = Map.new(extracted, fn {name, contents} -> {List.to_string(name), contents} end)
    manifest = Jason.decode!(files["manifest.json"])
    assert manifest["company_id"] == 73
    refute Enum.any?(Map.keys(files), &String.starts_with?(&1, "audit-"))
    assert manifest["tenant_id"] == 41
    assert manifest["through_entry_number"] == 501
    assert manifest["timezone"] == "Etc/UTC"
    assert manifest["generator_version"] == "5"
    assert manifest["files"]["ledger-entry.csv"]["row_count"] == 501
    assert manifest["files"]["ledger-line.csv"]["row_count"] == 1002
    assert manifest["files"]["general-ledger.csv"]["row_count"] == 1002
    assert manifest["control_totals"] == %{"debits" => "616.2300", "credits" => "616.2300"}
    assert manifest["files"]["ledger-line.csv"]["debits"] == "616.2300"
    assert manifest["files"]["ledger-line.csv"]["credits"] == "616.2300"
    assert files["ledger-line.csv"] =~ "1.2300"
    assert files["ledger-account.csv"] =~ "'="

    for {filename, meta} <- manifest["files"] do
      assert hash(files[filename]) == meta["sha256"]
    end

    assert length(String.split(files["ledger-line.csv"], "\r\n", trim: true)) == 1003
    # Empty evidence sections are explicit files with a zero count, not silently omitted.
    assert manifest["files"]["payables-document.csv"]["row_count"] == 0
    assert manifest["files"]["reconciliation-reconciliation_event.csv"]["row_count"] == 0

    for filename <-
          ~w(ledger-journal.csv ledger-journal_line.csv ledger-journal_event.csv
             ledger-approval_exception.csv ledger-approval_exception_review.csv
             ledger-duty_separation_change.csv payables-payment_request.csv
             payables-payment_request_allocation.csv payables-payment_request_event.csv
             einvoice-code_override.csv payroll-settings.csv payroll-settings_change.csv
             payroll-mapping.csv payroll-mapping_change.csv payroll-posting_event.csv
             sst-registration.csv sst-mapping.csv sst-return.csv sst-return_event.csv
             sst-return_box.csv sst-return_account.csv sst-return_source.csv
             sst-adjustment.csv einvoice-source_link.csv fixed_assets-category.csv
             fixed_assets-category_revision.csv fixed_assets-asset.csv fixed_assets-run.csv
             fixed_assets-run_item.csv fixed_assets-run_exception.csv fixed_assets-event.csv) do
      assert manifest["files"][filename]["row_count"] == 0
    end
  end

  test "only this company's evidence leaves the archive; read access is rechecked", context do
    %{first_scope: first, second_scope: second, operator: operator, accounts: accounts} = context

    sibling =
      Ledger.TestFixtures.sign_in!(first, 74, 93, [
        "finance.ledger.view",
        "finance.ledger.accounts.manage",
        "finance.ledger.entries.post",
        "finance.reports.reports-export"
      ])

    {:ok, _} = Ledger.open_book(sibling, 74, %{currency_code: "XTS", minor_units: 2})
    chart = TestFixtures.chart!(sibling, 74)

    TestFixtures.post!(
      sibling,
      chart,
      ~D[2026-10-01],
      [{"1010", :debit, "999"}, {"3000", :credit, "999"}],
      74
    )

    TestFixtures.post!(operator, accounts, ~D[2026-10-01], [
      {"1010", :debit, "1"},
      {"3000", :credit, "1"}
    ])

    {:ok, _} =
      Audit.record_action(first, %{
        company_id: 74,
        actor_type: "user",
        actor_id: 93,
        event: "other-company-secret",
        occurred_at: NaiveDateTime.utc_now()
      })

    assert {:ok, artifact} = Reports.export_auditor_pack(operator, 73, ~D[2026-10-31])
    assert {:ok, %{bytes: bytes}} = Reports.read_auditor_pack(operator, 73, artifact.id)
    {:ok, files} = :zip.extract(bytes, [:memory])

    refute Enum.any?(files, fn {_name, contents} ->
             String.contains?(contents, "other-company-secret")
           end)

    assert {:error, :unauthorized} = Reports.read_auditor_pack(sibling, 73, artifact.id)
    other = Ledger.TestFixtures.sign_in!(second, 75, 94, ["finance.reports.reports-export"])
    assert {:error, :company_not_found} = Reports.read_auditor_pack(other, 73, artifact.id)
    Ledger.TestFixtures.revoke!(first, 73, 91, "finance.payables.view")
    assert {:error, :forbidden} = Reports.read_auditor_pack(operator, 73, artifact.id)
    assert {:error, :unauthorized} = Reports.export_auditor_pack(operator, 73, ~D[2026-10-31])
  end

  test "AR/AP details, lifecycle and finalised reconciliation evidence carry source-file hashes",
       context do
    alias Bilimbi.Finance.{Receivables, Payables, Reconciliation}

    grants =
      Receivables.TestFixtures.receivables_capabilities() ++
        Payables.PayablesCase.all_capabilities() ++
        Reconciliation.ReconciliationCase.all_capabilities()

    operator = Ledger.TestFixtures.sign_in!(context.first_scope, 73, 91, grants)
    approver = Ledger.TestFixtures.sign_in!(context.first_scope, 73, 92, grants)

    ar_context =
      Receivables.TestFixtures.configure_receivables!(%{
        operator: operator,
        accounts: %{
          receivable: context.accounts["1500"],
          income: context.accounts["4000"],
          tax: context.accounts["2100"]
        }
      })

    {:ok, draft} =
      Receivables.create_draft(operator, 73, %{
        kind: "invoice",
        series_id: ar_context.invoice_series.id,
        customer_id: ar_context.customer.id,
        issue_date: ~D[2026-10-01],
        lines: [%{description: "Service", quantity: "1", unit_price: "105.55"}]
      })

    {:ok, invoice} = Receivables.issue_document(operator, 73, draft.id)
    {:ok, issued} = Reports.issue_report(operator, 73, :aged_receivables, ~D[2026-10-31])

    {:ok, _} =
      Receivables.update_customer(operator, 73, ar_context.customer.id, %{
        name: "Later customer name"
      })

    {:ok, live} =
      Receivables.aged_receivables(operator, 73, ~D[2026-10-31],
        through_entry_number: issued.through_entry_number
      )

    assert hd(live.customers).name == "Later customer name"
    assert hd(issued.content["customers"])["name"] == "Example Customer"
    assert {:ok, ^issued} = Reports.get_issued_report(operator, 73, issued.id)

    ledger_reader =
      Ledger.TestFixtures.sign_in!(context.first_scope, 73, 96, ["finance.ledger.view"])

    assert {:error, :unauthorized} = Reports.get_issued_report(ledger_reader, 73, issued.id)

    {:ok, _} =
      Payables.put_settings(operator, 73, %{payable_account_id: context.accounts["2000"].id})

    {:ok, bill} =
      Payables.create_bill(operator, 73, %{
        party_key: "P",
        party_name: "Party P",
        party_document_number: "SOURCE-1",
        document_date: ~D[2026-10-01],
        lines: [
          %{account_id: context.accounts["5000"].id, description: "Service", amount: "50.50"}
        ]
      })

    {:ok, _} = Payables.approve_document(approver, 73, bill.id)
    {:ok, _} = Payables.post_document(operator, 73, bill.id)

    {:ok, bank} =
      Reconciliation.create_bank_account(operator, 73, %{
        name: "Operating",
        ledger_account_id: context.accounts["1010"].id,
        import_mapping: Reconciliation.TestFixtures.mapping()
      })

    entry =
      TestFixtures.post!(operator, context.accounts, ~D[2026-10-01], [
        {"1010", :debit, "17.10"},
        {"3000", :credit, "17.10"}
      ])

    csv = Reconciliation.TestFixtures.csv([["2026-10-01", "Deposit", "", "17.10", "17.10"]])

    {:ok, statement} =
      Reconciliation.import_statement(operator, 73, bank.id, %{
        file_name: "input.csv",
        content: csv
      })

    {:ok, _match} =
      Reconciliation.match(operator, 73, bank.id, %{
        statement_line_ids: [hd(statement.lines).id],
        entry_ids: [entry.id]
      })

    {:ok, reconciliation} =
      Reconciliation.open_reconciliation(operator, 73, bank.id, %{
        end_date: ~D[2026-10-31],
        statement_balance: "17.10"
      })

    {:ok, _finalised} = Reconciliation.finalise_reconciliation(approver, 73, reconciliation.id)
    assert {:ok, artifact} = Reports.export_auditor_pack(operator, 73, ~D[2026-10-31])
    {:ok, %{bytes: bytes}} = Reports.read_auditor_pack(operator, 73, artifact.id)
    {:ok, extracted} = :zip.extract(bytes, [:memory])
    files = Map.new(extracted, fn {name, bytes} -> {List.to_string(name), bytes} end)
    manifest = Jason.decode!(files["manifest.json"])
    assert manifest["files"]["receivables-document.csv"]["row_count"] == 1
    assert files["ledger-entry.csv"] =~ "\"finance/receivables\""
    assert files["general-ledger.csv"] =~ "\"finance/receivables\""
    assert manifest["files"]["payables-document.csv"]["row_count"] == 1
    assert manifest["files"]["aged-receivables.json"]["row_count"] == 1
    assert manifest["files"]["aged-receivables.csv"]["row_count"] == 1
    assert manifest["files"]["aged-payables.json"]["row_count"] == 1
    assert manifest["files"]["aged-payables.csv"]["row_count"] == 1
    assert manifest["files"]["reconciliation-match_event.csv"]["row_count"] == 1
    assert manifest["files"]["reconciliation-reconciliation_event.csv"]["row_count"] == 2
    assert manifest["files"]["source-file-index.csv"]["row_count"] == 1
    assert files["source-file-index.csv"] =~ hash(csv)
    assert files["reconciliation-reconciliation_event.csv"] =~ "finalised"
    assert files["receivables-document.csv"] =~ invoice.document_reference
    assert files["payables-document.csv"] =~ "SOURCE-1"
  end

  test "CSV quotes arbitrary text and neutralizes formula and whitespace prefixes" do
    for text <- ["=1+1", "+cmd", "-cmd", "@SUM(1)", "  =1+1", "\t=1+1", "\rvalue", "\nvalue"] do
      assert Serialization.csv_row([text]) |> String.starts_with?("\"'")
    end

    assert Serialization.csv_row(["comma, quote\" and\nnewline"]) ==
             "\"comma, quote\"\" and\nnewline\"\r\n"

    assert Serialization.csv_row([Decimal.new("-1234567890123456.1234")]) ==
             "-1234567890123456.1234\r\n"
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
