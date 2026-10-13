defmodule Bilimbi.Finance.Payables.AttachmentsTest do
  use Bilimbi.Finance.Payables.PayablesCase

  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.TestFixtures, as: AttachmentsFixtures
  alias Bilimbi.Finance.Payables.Attachments.Bill
  alias Bilimbi.Finance.Payables.Attachments.Payment

  setup do
    AttachmentsFixtures.put_artifacts_root!()
    :ok
  end

  test "a bill's attachment is replaceable while draft and kept once approved", context do
    {:ok, bill} =
      Payables.create_bill(
        context.operator,
        73,
        bill("party", "INV-1", [line(context.accounts.stock, "100.00")])
      )

    assert {:ok, attachment} =
             Attachments.attach(
               context.operator,
               73,
               Bill,
               bill.id,
               AttachmentsFixtures.file("invoice.txt")
             )

    assert attachment.source == "finance/payables/document"
    assert attachment.document_label == "Bill (record #{bill.id})"
    assert attachment.document_date == ~D[2026-10-01]
    assert attachment.retain_until == ~U[2033-12-31 23:59:59.999999Z]

    assert {:ok, replacement} =
             Attachments.replace(
               context.operator,
               73,
               attachment.id,
               AttachmentsFixtures.file("invoice-2.txt")
             )

    {:ok, approved} = Payables.approve_document(context.approver, 73, bill.id)
    assert approved.status == "approved"

    assert {:error, :document_final} =
             Attachments.replace(
               context.operator,
               73,
               replacement.id,
               AttachmentsFixtures.file("late.txt")
             )

    assert {:error, :document_final} =
             Attachments.remove(context.operator, 73, replacement.id, %{reason: "no"})

    # More evidence can still be added, labelled by the number posting gave.
    {:ok, posted} = Payables.post_document(context.operator, 73, bill.id)

    assert {:ok, %{document_label: label}} =
             Attachments.attach(
               context.operator,
               73,
               Bill,
               bill.id,
               AttachmentsFixtures.file("delivery.txt")
             )

    assert label == "Bill #{posted.document_number}"

    assert {:ok, [_replacement, _delivery]} =
             Attachments.list_attachments(context.operator, 73, Bill, bill.id)
  end

  test "a payment request's attachment is kept once the payment posts", context do
    posted = post_bill!(context, bill("party", "INV-2", [line(context.accounts.stock, "50.00")]))

    {:ok, request} =
      Payables.submit_payment(context.operator, 73, %{
        party_key: "party",
        party_name: "Party party",
        payment_date: ~D[2026-10-05],
        paid_from_account_id: context.accounts.bank.id,
        amount: "50.00",
        allocations: [%{document_id: posted.id, amount: "50.00"}]
      })

    assert {:ok, attachment} =
             Attachments.attach(
               context.operator,
               73,
               Payment,
               request.id,
               AttachmentsFixtures.file("remittance.txt")
             )

    assert attachment.document_label == "Payment request #{request.request_number}"
    assert attachment.document_date == ~D[2026-10-05]

    {:ok, _payment} = Payables.approve_payment(context.approver, 73, request.id)

    assert {:error, :document_final} =
             Attachments.remove(context.operator, 73, attachment.id, %{reason: "no"})

    assert {:ok, %{bytes: "made-up scan"}} =
             Attachments.read_attachment(context.operator, 73, attachment.id)
  end

  test "the attachments grant without payables view shows no bill's file", context do
    {:ok, bill} =
      Payables.create_bill(
        context.operator,
        73,
        bill("party", "INV-3", [line(context.accounts.stock, "10.00")])
      )

    {:ok, attachment} =
      Attachments.attach(context.operator, 73, Bill, bill.id, AttachmentsFixtures.file())

    reader =
      Bilimbi.Finance.Payables.TestFixtures.sign_in!(
        context.first_scope,
        73,
        99,
        ~w(finance.attachments.view)
      )

    assert {:ok, []} = Attachments.list_attachments(reader, 73, Bill, bill.id)
    assert {:ok, []} = Attachments.list_company_attachments(reader, 73)
    assert {:error, :unauthorized} = Attachments.get_attachment(reader, 73, attachment.id)
  end

  test "the source answers payables' refusals", context do
    assert {:error, :document_not_found} = Bill.document(context.operator, 73, 999)

    assert {:error, :document_not_found} =
             Attachments.attach(context.operator, 73, Bill, 999, AttachmentsFixtures.file())

    assert {:error, :unauthorized} = Bill.document(context.first_scope, 73, 1)
  end
end
