defmodule Bilimbi.Finance.Receivables.AttachmentsTest do
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.TestFixtures, as: AttachmentsFixtures
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Receivables.Attachments.Document
  alias Bilimbi.Finance.Receivables.Attachments.Payment
  alias Bilimbi.Finance.Receivables.TestFixtures

  setup do
    context = TestFixtures.setup_receivables!() |> TestFixtures.configure_receivables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    AttachmentsFixtures.put_artifacts_root!()
    context
  end

  test "an invoice's attachment is replaceable while draft and kept once issued", context do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: ~D[2026-10-02],
        lines: [%{description: "Service", quantity: "1", unit_price: "100.00"}]
      })

    assert {:ok, attachment} =
             Attachments.attach(
               context.operator,
               73,
               Document,
               draft.id,
               AttachmentsFixtures.file("contract.txt")
             )

    assert attachment.source == "finance/receivables/document"
    assert attachment.document_label == "Invoice (draft #{draft.id})"
    assert attachment.document_date == ~D[2026-10-02]
    assert attachment.retain_until == ~U[2033-12-31 23:59:59.999999Z]

    assert {:ok, replacement} =
             Attachments.replace(
               context.operator,
               73,
               attachment.id,
               AttachmentsFixtures.file("contract-signed.txt")
             )

    {:ok, issued} = Receivables.issue_document(context.operator, 73, draft.id)

    assert {:error, :document_final} =
             Attachments.remove(context.operator, 73, replacement.id, %{reason: "no"})

    assert {:ok, %{document_label: label}} =
             Attachments.attach(
               context.operator,
               73,
               Document,
               draft.id,
               AttachmentsFixtures.file("delivery.txt")
             )

    assert label == "Invoice #{issued.document_number}"

    assert {:ok, [_contract, _delivery]} =
             Attachments.list_attachments(context.operator, 73, Document, draft.id)
  end

  test "issuing a re-dated draft extends its attachments to the issue date's retention",
       context do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: ~D[2026-03-01],
        lines: [%{description: "Service", quantity: "1", unit_price: "100.00"}]
      })

    {:ok, attachment} =
      Attachments.attach(
        context.operator,
        73,
        Document,
        draft.id,
        AttachmentsFixtures.file("contract.txt")
      )

    assert attachment.retain_until == ~U[2033-12-31 23:59:59.999999Z]

    {:ok, _draft} =
      Receivables.update_draft(context.operator, 73, draft.id, %{issue_date: ~D[2027-02-01]})

    assert {:ok, %{retain_until: ~U[2033-12-31 23:59:59.999999Z]}} =
             Attachments.get_attachment(context.operator, 73, attachment.id)

    {:ok, _issued} = Receivables.issue_document(context.operator, 73, draft.id)

    assert {:ok, %{retain_until: ~U[2034-12-31 23:59:59.999999Z], events: [event]}} =
             Attachments.get_attachment(context.operator, 73, attachment.id)

    assert event.event == "retention_extended"

    assert {:ok, %{metadata: %{retain_until: ~U[2034-12-31 23:59:59.999999Z]}}} =
             Bilimbi.Base.Artifacts.read(
               context.operator,
               73,
               Bilimbi.Finance.Attachments.ArtifactOwner,
               attachment.artifact_id
             )
  end

  test "a payment received is final from the start", context do
    {:ok, invoice} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: ~D[2026-10-02],
        lines: [%{description: "Service", quantity: "1", unit_price: "40.00"}]
      })

    {:ok, invoice} = Receivables.issue_document(context.operator, 73, invoice.id)

    {:ok, payment} =
      Receivables.record_payment(context.operator, 73, %{
        series_id: context.payment_series.id,
        customer_id: context.customer.id,
        payment_date: ~D[2026-10-09],
        amount: "40.00",
        deposit_account_id: context.accounts.cash.id,
        allocations: [%{document_id: invoice.id, amount: "40.00"}]
      })

    assert {:ok, attachment} =
             Attachments.attach(
               context.operator,
               73,
               Payment,
               payment.id,
               AttachmentsFixtures.file("remittance.txt")
             )

    assert attachment.document_label == "Payment #{payment.payment_number}"
    assert attachment.document_date == ~D[2026-10-09]

    assert {:error, :document_final} =
             Attachments.replace(context.operator, 73, attachment.id, AttachmentsFixtures.file())

    assert {:ok, %{bytes: "made-up scan"}} =
             Attachments.read_attachment(context.operator, 73, attachment.id)
  end

  test "the attachments grant without receivables view shows no document's file", context do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: ~D[2026-10-02],
        lines: [%{description: "Service", quantity: "1", unit_price: "100.00"}]
      })

    {:ok, attachment} =
      Attachments.attach(context.operator, 73, Document, draft.id, AttachmentsFixtures.file())

    reader = TestFixtures.sign_in!(context.first_scope, 73, 99, ~w(finance.attachments.view))

    assert {:ok, []} = Attachments.list_attachments(reader, 73, Document, draft.id)
    assert {:ok, []} = Attachments.list_company_attachments(reader, 73)
    assert {:error, :unauthorized} = Attachments.get_attachment(reader, 73, attachment.id)
  end

  test "the sources answer receivables' refusals", context do
    assert {:error, :document_not_found} = Document.document(context.operator, 73, 999)
    assert {:error, :payment_not_found} = Payment.document(context.operator, 73, 999)
    assert {:error, :unauthorized} = Document.document(context.first_scope, 73, 1)
  end
end
