defmodule Bilimbi.Finance.Einvoice.DocumentsTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Artifacts
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Einvoice

  alias Bilimbi.Finance.Einvoice.{
    ArtifactOwner,
    Document,
    Documents,
    Line,
    StatusEvent,
    Submission,
    TestFixtures
  }

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())
    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    Map.put(context, :operator, operator)
  end

  describe "paging and filtering" do
    test "pages newest first and filters by status, type, environment, and search", %{
      operator: op
    } do
      documents =
        for n <- 1..3 do
          {:ok, document} =
            Einvoice.issue_document(
              op,
              73,
              TestFixtures.invoice_attributes(%{code_number: "INV-#{n}"})
            )

          document
        end

      [first, second, third] = documents
      :ok = TestFixtures.validate!(op, 73, second.id)

      assert {:ok, page} = Einvoice.page_documents(op, 73, page_size: 25)
      assert Enum.map(page.entries, & &1.code_number) == ["INV-3", "INV-2", "INV-1"]
      assert Enum.map(page.entries, & &1.status) == ["issued", "valid", "issued"]
      assert %{total_entries: 3, total_pages: 1, page: 1, has_next?: false} = page

      assert {:ok, %{entries: [%{id: id}]}} = Einvoice.page_documents(op, 73, status: "valid")
      assert id == second.id

      assert {:ok, %{entries: [%{id: id}]}} = Einvoice.page_documents(op, 73, search: "inv-1")
      assert id == first.id

      assert {:ok, %{entries: [_, _, _]}} = Einvoice.page_documents(op, 73, search: "buyer's")
      assert {:ok, %{entries: []}} = Einvoice.page_documents(op, 73, search: "%")
      assert {:ok, %{entries: []}} = Einvoice.page_documents(op, 73, document_type: "02")

      assert {:ok, %{entries: [_, _, _]}} =
               Einvoice.page_documents(op, 73, environment: "sandbox")

      assert {:ok, %{entries: []}} = Einvoice.page_documents(op, 73, environment: "production")

      # The facade takes the page sizes the list offers; the query pages any size.
      assert %{entries: [%{id: id}], total_pages: 3, page: 2, has_prev?: true, has_next?: true} =
               Documents.page(op, 73, page: 2, page_size: 1)

      assert id == second.id
      assert %{entries: [%{id: id}], page: 3} = Documents.page(op, 73, page: 9, page_size: 1)
      assert id == first.id and third.id > second.id
      assert {:error, :invalid_option} = Einvoice.page_documents(op, 73, page_size: 7)
      assert {:error, :invalid_option} = Einvoice.page_documents(op, 73, page: 0)
    end

    test "needs the view capability and the company", %{operator: op} = context do
      stranger = TestFixtures.sign_in!(context.first_scope, 73, 92, [])
      assert {:error, :unauthorized} = Einvoice.page_documents(stranger, 73)
      assert {:error, :unauthorized} = Einvoice.reconciliation(stranger, 73)
      assert {:error, :company_not_found} = Einvoice.page_documents(op, 75)
    end
  end

  describe "the printable document" do
    test "renders a PDF through Base Artifacts, records it, and reads it back", %{operator: op} do
      TestFixtures.put_artifacts_root!()
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      :ok = TestFixtures.validate!(op, 73, document.id)

      assert {:ok, %{artifact_id: artifact_id, byte_size: size, sha256: sha256}} =
               Einvoice.generate_pdf(op, 73, document.id)

      assert size > 0 and byte_size(sha256) == 64

      assert {:ok, %{bytes: <<"%PDF-", _::binary>> = bytes, filename: filename}} =
               Einvoice.read_pdf(op, 73, artifact_id)

      assert filename == "e-invoice-#{document.id}.pdf"
      assert bytes =~ "JSON-INV12345"
      assert bytes =~ "F9D425P6DS7D8IU/share/"

      assert {:ok, %{pdf_artifact_id: ^artifact_id, events: events}} =
               Einvoice.get_document(op, 73, document.id)

      assert %{event: "pdf_generated", response: %{"artifact_id" => ^artifact_id}} =
               List.last(events)

      # Reading goes through the owner's authorization every time.
      assert {:ok, _} = Artifacts.read(op, 73, ArtifactOwner, artifact_id)
      assert {:error, _} = Einvoice.read_pdf(op, 74, artifact_id)
      assert {:error, :not_found} = Einvoice.read_pdf(op, 73, nil)
    end

    test "asking again for an unchanged document returns the stored PDF and records nothing",
         %{operator: op} do
      TestFixtures.put_artifacts_root!()
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      :ok = TestFixtures.validate!(op, 73, document.id)

      assert {:ok, %{artifact_id: artifact_id} = first} =
               Einvoice.generate_pdf(op, 73, document.id)

      assert {:ok, ^first} = Einvoice.generate_pdf(op, 73, document.id)

      assert {:ok, %{events: events}} = Einvoice.get_document(op, 73, document.id)
      assert [%{response: %{"artifact_id" => ^artifact_id}}] = pdf_events(events)

      assert [[%{"artifact_id" => ^artifact_id}]] =
               Bilimbi.Base.Audit.TestFixtures.action_payloads("finance.einvoice.pdf.generated")
    end

    test "a document that gained an event gets a new PDF", %{operator: op} do
      TestFixtures.put_artifacts_root!()
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      :ok = TestFixtures.validate!(op, 73, document.id)

      assert {:ok, %{artifact_id: first_id}} = Einvoice.generate_pdf(op, 73, document.id)
      Documents.record_event!(op, 73, document.id, %{event: "status_checked"})
      assert {:ok, %{artifact_id: second_id}} = Einvoice.generate_pdf(op, 73, document.id)
      refute second_id == first_id

      assert {:ok, %{events: events, pdf_artifact_id: ^second_id}} =
               Einvoice.get_document(op, 73, document.id)

      assert [_, _] = pdf_events(events)
      assert {:ok, %{artifact_id: ^second_id}} = Einvoice.generate_pdf(op, 73, document.id)

      assert [_, _] =
               Bilimbi.Base.Audit.TestFixtures.action_payloads("finance.einvoice.pdf.generated")
    end

    test "refuses without storage configured", %{operator: op} do
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      assert {:error, _reason} = Einvoice.generate_pdf(op, 73, document.id)
      assert {:ok, %{pdf_artifact_id: nil}} = Einvoice.get_document(op, 73, document.id)
    end
  end

  describe "authority rules" do
    test "the pages, the PDF, and the cancellation window read the authority's rules" do
      authority = Bilimbi.Finance.Einvoice.Configuration.authority()

      assert authority.posting_rule("01") == {:debit, :receivable_account}
      assert authority.posting_rule("02") == {:credit, :receivable_account}
      assert authority.posting_rule("03") == {:debit, :receivable_account}
      assert authority.posting_rule("04") == {:credit, :settlement_account}
      assert authority.posting_rule("99") == nil
      assert authority.document_type_name("02") == "Credit note"
      assert Documents.cancellation_window_hours() == authority.cancellation_window_hours()
    end

    test "an event's reason is kept to the column's length", %{operator: op} do
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      event =
        Documents.record_event!(op, 73, document.id, %{
          event: "search_deferred",
          reason: String.duplicate("x", 400)
        })

      assert String.length(event.reason) == 300
    end
  end

  describe "retention" do
    test "nothing a document accumulated can be changed or removed", %{operator: op} do
      {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      :ok = TestFixtures.validate!(op, 73, document.id)

      Documents.record_event!(op, 73, document.id, %{event: "posted", ledger_entry_id: 1})

      submission =
        Repo.insert!(%Submission{
          tenant_id: 41,
          company_id: 73,
          document_id: document.id,
          environment: "sandbox",
          format: "JSON",
          document_version: "1.0",
          payload: "{}",
          payload_sha256: :sha256 |> :crypto.hash("{}") |> Base.encode16(case: :lower),
          actor_type: "user",
          actor_user_id: 91
        })

      for {schema, id} <- [
            {Document, document.id},
            {Line, Repo.one!(from(l in Line, select: l.id, limit: 1))},
            {Submission, submission.id},
            {StatusEvent, Repo.one!(from(e in StatusEvent, select: max(e.id)))}
          ] do
        assert_raise Postgrex.Error, ~r/finance e-invoicing keeps/, fn ->
          Repo.delete!(Repo.get!(schema, id))
        end

        assert_raise Postgrex.Error, ~r/finance e-invoicing keeps/, fn ->
          Repo.update_all(from(r in schema, where: r.id == ^id), set: [company_id: 73])
        end
      end

      assert_raise Ecto.ConstraintError, ~r/ledger_entry_id/, fn ->
        Documents.record_event!(op, 73, document.id, %{event: "posted", ledger_entry_id: 0})
      end

      assert {:ok, %{events: events}} = Einvoice.get_document(op, 73, document.id)
      assert Enum.map(events, & &1.event) == ["issued", "submitted", "valid", "posted"]
    end
  end

  defp pdf_events(events), do: Enum.filter(events, &(&1.event == "pdf_generated"))
end
