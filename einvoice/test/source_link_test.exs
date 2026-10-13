defmodule Bilimbi.Finance.Einvoice.SourceLinkTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{Documents, Posting, TestFixtures}
  alias Bilimbi.Finance.Ledger

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @receivables "finance/receivables"
  @payables "finance/payables"

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator =
      TestFixtures.sign_in!(
        context.first_scope,
        73,
        91,
        TestFixtures.capabilities() ++ TestFixtures.ledger_capabilities()
      )

    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    accounts = TestFixtures.open_posting_book!(operator, 73)
    Map.merge(context, %{operator: operator, accounts: accounts})
  end

  # What a receivables invoice (or, mirrored, its credit note) posts for
  # the fixture's sale of 170.00 plus 10.20 tax, as that module's record.
  defp sale_entry!(op, accounts, record, options \\ []) do
    {debit, credit} =
      if Keyword.get(options, :mirror, false), do: {:credit, :debit}, else: {:debit, :credit}

    gross = Keyword.get(options, :gross, "180.20")
    net = Keyword.get(options, :net, "170.00")
    tax = Keyword.get(options, :tax, "10.20")

    lines =
      [
        %{:account_id => accounts.receivable_account.id, debit => gross},
        %{:account_id => accounts.revenue_account.id, credit => net},
        %{:account_id => accounts.tax_account.id, credit => tax}
      ]
      |> Enum.reject(fn line -> line |> Map.values() |> Enum.member?("0.00") end)

    {:ok, entry} =
      Ledger.post_entry(
        op,
        73,
        %{entry_date: ~D[2026-10-01], description: "Invoice", lines: lines},
        owner: owner(record)
      )

    entry
  end

  defp owner(record, module \\ @receivables), do: %{module: module, record: record}

  defp source(entry, record, module \\ @receivables),
    do: %{module: module, record: record, ledger_entry_id: entry.id}

  defp linked_invoice!(op, entry, record, overrides \\ %{}) do
    {:ok, document} =
      Einvoice.issue_document(
        op,
        73,
        TestFixtures.invoice_attributes(Map.merge(%{source: source(entry, record)}, overrides))
      )

    document
  end

  defp entry_count(op) do
    {:ok, entries} = Ledger.list_entries(op, 73)
    length(entries)
  end

  describe "a document issued for a transaction another module recognised" do
    test "links to it and never posts or reverses an entry of its own",
         %{operator: op, accounts: accounts} do
      entry = sale_entry!(op, accounts, "document:17")
      document = linked_invoice!(op, entry, "document:17")

      assert %{
               recognised_by_source?: true,
               source_links: [%{module: @receivables, record: "document:17", ledger_entry_id: id}],
               ledger_entry_id: nil,
               attention: []
             } = document

      assert id == entry.id

      :ok = TestFixtures.validate!(op, 73, document.id)
      {:ok, valid} = Einvoice.get_document(op, 73, document.id)
      assert %{status: "valid", attention: [], ledger_entry_id: nil} = valid

      # Clearance posts nothing; the sale stands once, as receivables posted it.
      assert :noop = Posting.post(op, 73, valid)

      assert {:ok, %{id: retried_id, ledger_entry_id: nil}} =
               Einvoice.retry_posting(op, 73, document.id)

      assert retried_id == document.id
      assert entry_count(op) == 1
      assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)

      # Cancellation changes nothing in the ledger either: the correction is
      # the owner's, and the ledger refuses a direct reversal of its entry.
      Documents.record_event!(op, 73, document.id, %{event: "cancelled", reason: "Wrong buyer"})
      {:ok, cancelled} = Einvoice.get_document(op, 73, document.id)
      assert %{status: "cancelled", attention: [], reversal_entry_id: nil} = cancelled
      assert :noop = Posting.reverse(op, 73, cancelled, DateTime.utc_now())
      assert {:ok, %{reversal_entry_id: nil}} = Einvoice.retry_reversal(op, 73, document.id)
      assert entry_count(op) == 1
      assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)

      assert {:error, {:owned_by, %{module: @receivables, record: "document:17"}}} =
               Ledger.reverse_entry(op, 73, entry.id, %{
                 entry_date: ~D[2026-10-02],
                 description: "Undo"
               })

      assert {:ok, [only]} = Ledger.list_entries(op, 73)
      assert only.id == entry.id and only.reversed_by_entry_id == nil
    end

    test "issue, clearance, and a credit note leave exactly the owner's two entries",
         %{operator: op, accounts: accounts} do
      invoice_entry = sale_entry!(op, accounts, "document:17")
      invoice = linked_invoice!(op, invoice_entry, "document:17")
      :ok = TestFixtures.validate!(op, 73, invoice.id)
      {:ok, valid} = Einvoice.get_document(op, 73, invoice.id)
      assert :noop = Posting.post(op, 73, valid)

      # Receivables corrects the sale with a credit note of its own, which
      # posts the mirror entry; the credit note e-invoice links to that.
      credit_entry = sale_entry!(op, accounts, "document:18", mirror: true)

      {:ok, note} =
        Einvoice.issue_document(
          op,
          73,
          TestFixtures.invoice_attributes(%{
            document_type: "02",
            code_number: "CN-1",
            original_document_id: invoice.id,
            source: source(credit_entry, "document:18")
          })
        )

      assert %{source_links: [%{record: "document:18"}], recognised_by_source?: true} = note
      :ok = TestFixtures.validate!(op, 73, note.id, uuid: "NOTEUUID00000001")
      {:ok, valid_note} = Einvoice.get_document(op, 73, note.id)
      assert :noop = Posting.post(op, 73, valid_note)

      assert {:ok, entries} = Ledger.list_entries(op, 73)
      assert Enum.map(entries, & &1.owner) == [owner("document:17"), owner("document:18")]
      assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)
    end

    test "a self-billed document links to the bill payables recognised",
         %{operator: op, accounts: _accounts} do
      purchase = TestFixtures.add_purchase_accounts!(op, 73)

      {:ok, entry} =
        Ledger.post_entry(
          op,
          73,
          %{
            entry_date: ~D[2026-10-01],
            description: "Bill",
            lines: [
              %{account_id: purchase.expense_account.id, debit: "100.00"},
              %{account_id: purchase.payable_account.id, credit: "100.00"}
            ]
          },
          owner: owner("document:3", @payables)
        )

      {:ok, document} =
        Einvoice.issue_document(
          op,
          73,
          TestFixtures.self_billed_attributes(%{source: source(entry, "document:3", @payables)})
        )

      assert %{self_billed?: true, source_links: [%{module: @payables, record: "document:3"}]} =
               document

      :ok = TestFixtures.validate!(op, 73, document.id)
      {:ok, valid} = Einvoice.get_document(op, 73, document.id)
      assert :noop = Posting.post(op, 73, valid)
      assert entry_count(op) == 1
    end

    test "a document issued without a source still posts, as before",
         %{operator: op} do
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      assert %{source_links: [], recognised_by_source?: false, attention: []} = document
      :ok = TestFixtures.validate!(op, 73, document.id)
      {:ok, valid} = Einvoice.get_document(op, 73, document.id)
      assert %{attention: [:unposted]} = valid
      assert {:ok, entry} = Posting.post(op, 73, valid)
      assert entry.owner == %{module: "finance/einvoice", record: "document:#{document.id}"}
    end
  end

  describe "the source is held to the ledger" do
    test "refuses an entry the ledger does not hold for that owner and amount",
         %{operator: op, accounts: accounts} do
      entry = sale_entry!(op, accounts, "document:17")

      {:ok, manual} =
        Ledger.post_entry(op, 73, %{
          entry_date: ~D[2026-10-01],
          description: "Manual",
          lines: [
            %{account_id: accounts.receivable_account.id, debit: "180.20"},
            %{account_id: accounts.revenue_account.id, credit: "180.20"}
          ]
        })

      short =
        sale_entry!(op, accounts, "document:19", gross: "100.00", net: "100.00", tax: "0.00")

      refused = fn source ->
        assert {:error, changeset} =
                 Einvoice.issue_document(
                   op,
                   73,
                   TestFixtures.invoice_attributes(%{source: source})
                 )

        %{source: [message]} = errors_on(changeset)
        message
      end

      assert refused.(source(%{id: entry.id + 1000}, "document:17")) =~ "does not exist"

      assert refused.(source(manual, "document:17")) =~
               "is not owned by finance/receivables document:17"

      assert refused.(source(entry, "document:18")) =~
               "is not owned by finance/receivables document:18"

      assert refused.(source(entry, "document:17", @payables)) =~
               "is not owned by finance/payables"

      assert refused.(source(short, "document:19")) =~
               "recognises 100.00, not the document's 180.20"

      for shape <- [
            "finance/receivables document:17",
            %{module: @receivables, record: "document:17"},
            %{module: "Receivables", record: "document:17", ledger_entry_id: entry.id},
            %{module: @receivables, record: "document 17", ledger_entry_id: entry.id},
            %{module: @receivables, record: "document:17", ledger_entry_id: "#{entry.id}"}
          ] do
        assert refused.(shape) == "names a module, a record, and a ledger entry"
      end

      # A reversal, and an entry since reversed, recognise nothing.
      {:ok, reversal} =
        Ledger.reverse_owned_entry(op, 73, entry.id, owner("document:17"), %{
          entry_date: ~D[2026-10-02],
          description: "Reversal"
        })

      assert refused.(source(reversal, "document:17")) =~ "is a reversal"
      assert refused.(source(entry, "document:17")) =~ "was reversed by entry #{reversal.id}"

      assert {:ok, []} = Einvoice.list_documents(op, 73)
    end

    test "needs the ledger's view grant to read the entry",
         %{operator: op, accounts: accounts} = c do
      entry = sale_entry!(op, accounts, "document:17")
      issuer = TestFixtures.sign_in!(c.first_scope, 73, 92, TestFixtures.capabilities())

      assert {:error, changeset} =
               Einvoice.issue_document(
                 issuer,
                 73,
                 TestFixtures.invoice_attributes(%{source: source(entry, "document:17")})
               )

      assert %{source: ["cannot read ledger entry #{entry.id}: :unauthorized"]} ==
               errors_on(changeset)
    end

    test "a source has one standing document", %{operator: op, accounts: accounts} do
      entry = sale_entry!(op, accounts, "document:17")

      # An issued document the authority never saw does not stand: it may be
      # replaced, and it is then never submitted (the migration's rule).
      first = linked_invoice!(op, entry, "document:17")
      second = linked_invoice!(op, entry, "document:17", %{code_number: "INV-2"})
      :ok = TestFixtures.validate!(op, 73, second.id)

      assert {:error, changeset} =
               Einvoice.issue_document(
                 op,
                 73,
                 TestFixtures.invoice_attributes(%{
                   code_number: "INV-3",
                   source: source(entry, "document:17")
                 })
               )

      assert %{source: ["is already the source of document #{second.id}, which stands"]} ==
               errors_on(changeset)

      assert first.id < second.id

      Documents.record_event!(op, 73, second.id, %{event: "cancelled", reason: "Wrong buyer"})

      assert {:ok, %{source_links: [_link]}} =
               Einvoice.issue_document(
                 op,
                 73,
                 TestFixtures.invoice_attributes(%{
                   code_number: "INV-3",
                   source: source(entry, "document:17")
                 })
               )
    end
  end

  describe "a consolidated document" do
    setup %{first_scope: scope} do
      :ok = TestFixtures.put_settings!(scope, 73, %{"document_version" => "1.0"})
      # Inside September's window, which opens when the month ends.
      Application.put_env(:bilimbi_finance_einvoice, :clock, fn -> ~U[2026-10-03 02:00:00Z] end)
      on_exit(fn -> Application.delete_env(:bilimbi_finance_einvoice, :clock) end)
      :ok
    end

    defp september!(op, entry, record, code_number) do
      linked_invoice!(op, entry, record, %{
        code_number: code_number,
        issued_at: ~U[2026-09-02 04:00:00Z]
      })
    end

    test "carries its sources' links and never posts", %{operator: op, accounts: accounts} do
      one = sale_entry!(op, accounts, "document:21")
      two = sale_entry!(op, accounts, "document:22")
      _first = september!(op, one, "document:21", "S-1")
      _second = september!(op, two, "document:22", "S-2")

      assert {:ok, consolidated} =
               Einvoice.issue_consolidated_document(op, 73, %{
                 month: "2026-09",
                 code_number: "CON-2026-09"
               })

      assert %{recognised_by_source?: true, source_links: links} = consolidated
      assert Enum.map(links, & &1.record) == ["document:21", "document:22"]

      :ok = TestFixtures.validate!(op, 73, consolidated.id)
      {:ok, valid} = Einvoice.get_document(op, 73, consolidated.id)
      assert %{attention: []} = valid
      assert :noop = Posting.post(op, 73, valid)
      assert entry_count(op) == 2
    end

    test "does not mix sources with links and without", %{operator: op, accounts: accounts} do
      one = sale_entry!(op, accounts, "document:21")
      _linked = september!(op, one, "document:21", "S-1")

      {:ok, _plain} =
        Einvoice.issue_document(
          op,
          73,
          TestFixtures.invoice_attributes(%{
            code_number: "S-2",
            issued_at: ~U[2026-09-03 04:00:00Z]
          })
        )

      assert {:error, :mixed_source_links} =
               Einvoice.issue_consolidated_document(op, 73, %{
                 month: "2026-09",
                 code_number: "CON-2026-09"
               })
    end
  end
end
