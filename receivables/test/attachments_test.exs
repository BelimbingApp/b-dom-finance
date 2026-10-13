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

  test "issuing a re-dated draft queues the extension of its attachments", context do
    issuer = issuer!(context, TestFixtures.ledger_capabilities())
    {:ok, draft, attachment} = draft_with_contract!(context)
    assert attachment.retain_until == ~U[2033-12-31 23:59:59.999999Z]

    {:ok, _draft} =
      Receivables.update_draft(issuer, 73, draft.id, %{issue_date: ~D[2027-02-01]})

    assert {:ok, %{retention_refresh: :queued}} = Receivables.issue_document(issuer, 73, draft.id)

    assert {:ok, %{retain_until: ~U[2033-12-31 23:59:59.999999Z]}} =
             Attachments.get_attachment(context.operator, 73, attachment.id)

    assert :ok = perform_refresh_job!()

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

  test "a refresh job Base Artifacts refuses fails for the queue to retry, and what it extended stays",
       context do
    {:ok, draft, attachment} = draft_with_contract!(context)
    orphan!(attachment.id)

    {:ok, _draft} =
      Receivables.update_draft(context.operator, 73, draft.id, %{issue_date: ~D[2027-02-01]})

    assert {:ok, %{status: "issued", retention_refresh: :queued}} =
             Receivables.issue_document(context.operator, 73, draft.id)

    assert {:error, :retention_refresh_failed} = perform_refresh_job!()

    assert {:ok, %{retain_until: ~U[2034-12-31 23:59:59.999999Z]}} =
             Attachments.get_attachment(context.operator, 73, attachment.id)
  end

  test "an issue with no source documents queues nothing", context do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: ~D[2026-03-01],
        lines: [%{description: "Service", quantity: "1", unit_price: "100.00"}]
      })

    assert {:ok, %{retention_refresh: :none}} =
             Receivables.issue_document(context.operator, 73, draft.id)
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

  defp issuer!(context, extra) do
    TestFixtures.sign_in!(
      context.first_scope,
      73,
      99,
      TestFixtures.receivables_capabilities() ++ extra
    )
  end

  defp draft_with_contract!(context) do
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

    {:ok, draft, attachment}
  end

  defp orphan!(attachment_id) do
    Ecto.Adapters.SQL.query!(
      Bilimbi.Base.Repo,
      """
      INSERT INTO finance_attachments (tenant_id, company_id, source, source_module, document_id,
        document_label, document_date, artifact_id, file_name, content_type, byte_size, sha256,
        retention_years, retain_until, captured_by_user_id)
      SELECT tenant_id, company_id, source, source_module, document_id, document_label,
        document_date, gen_random_uuid(), file_name, content_type, byte_size, sha256,
        retention_years, retain_until, captured_by_user_id
      FROM finance_attachments WHERE id = $1
      """,
      [attachment_id]
    )
  end

  defp perform_refresh_job! do
    import Ecto.Query
    worker = Bilimbi.Finance.Attachments.RetentionRefreshWorker

    job =
      Bilimbi.Base.Repo.one!(
        from(j in Oban.Job,
          where: j.worker == ^"#{inspect(worker)}.ObanAdapter",
          order_by: [desc: j.id],
          limit: 1
        )
      )

    Bilimbi.Base.Queue.Worker.perform(worker, job)
  end
end
