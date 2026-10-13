defmodule BilimbiWeb.PayablesBillAttachmentsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.TestFixtures, as: AttachmentsFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Payables.Attachments.Bill
  alias Bilimbi.Finance.Payables.{StubOrderSource, TestFixtures}

  @view "finance.payables.view"
  @attachments_view "finance.attachments.view"
  @attachments_create "finance.attachments.create"
  @attachments_delete "finance.attachments.delete"
  @ledger_view "finance.ledger.view"

  setup do
    signed_in_identity!()
    AttachmentsFixtures.create_artifacts_tables!()
    Ledger.TestFixtures.create_ledger_tables!()
    AttachmentsFixtures.create_attachments_tables!()
    TestFixtures.create_payables_tables!()
    AttachmentsFixtures.put_artifacts_root!()
    StubOrderSource.install!()
    on_exit(&StubOrderSource.uninstall!/0)
    {:ok, scope} = Tenancy.scope(41)

    keeper =
      TestFixtures.sign_in!(scope, 73, 92, Bilimbi.Finance.Payables.PayablesCase.all_capabilities())

    {:ok, _book} = Ledger.open_book(keeper, 73, %{currency_code: "XTS", minor_units: 2})

    {:ok, stock} =
      Ledger.create_account(keeper, 73, %{code: "1200", name: "Stock", account_type: "asset"})

    {:ok, payable} =
      Ledger.create_account(keeper, 73, %{code: "2000", name: "Payable", account_type: "liability"})

    {:ok, _} = Payables.put_settings(keeper, 73, %{payable_account_id: payable.id})

    {:ok, bill} =
      Payables.create_bill(keeper, 73, %{
        party_key: "party",
        party_name: "Party",
        party_document_number: "INV-9",
        document_date: ~D[2026-10-01],
        lines: [%{description: "Line", account_id: stock.id, amount: "100.00"}]
      })

    %{scope: scope, keeper: keeper, bill: bill}
  end

  test "the bill page lists the bill's source documents and withholds the form", %{conn: conn, keeper: keeper, bill: bill} do
    {:ok, attachment} = Attachments.attach(keeper, 73, Bill, bill.id, AttachmentsFixtures.file("invoice.txt"))
    grant_capabilities!([@view, @ledger_view, @attachments_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{bill.id}")

    assert has_element?(view, "#payables-bill-attachments-#{attachment.id}", "invoice.txt")
    assert has_element?(view, "#payables-bill-attachments-#{attachment.id}-download")
    refute has_element?(view, "#payables-bill-attachments-form")
    refute has_element?(view, "#payables-bill-attachments-#{attachment.id}-remove")
  end

  test "attaches, replaces, and removes a draft bill's file from its page", %{conn: conn, keeper: keeper, bill: bill} do
    grant_capabilities!([@view, @ledger_view, @attachments_view, @attachments_create, @attachments_delete])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{bill.id}")

    assert has_element?(view, "#payables-bill-attachments-form")

    upload = file_input(view, "#payables-bill-attachments-form", :file, [
      %{name: "invoice.txt", content: "the party's invoice", type: "text/plain"}
    ])

    render_upload(upload, "invoice.txt")
    view |> form("#payables-bill-attachments-form") |> render_submit()

    assert {:ok, [attachment]} = Attachments.list_attachments(keeper, 73, Bill, bill.id)
    assert attachment.file_name == "invoice.txt"
    assert has_element?(view, "#payables-bill-attachments-#{attachment.id}", "invoice.txt")
    assert has_element?(view, "#payables-bill-attachments-notice", "2033-12-31")

    view |> element("#payables-bill-attachments-#{attachment.id}-replace") |> render_click()
    assert has_element?(view, "#payables-bill-attachments-replacing")

    upload = file_input(view, "#payables-bill-attachments-form", :file, [
      %{name: "invoice-2.txt", content: "the corrected invoice", type: "text/plain"}
    ])

    render_upload(upload, "invoice-2.txt")
    view |> form("#payables-bill-attachments-form") |> render_submit()

    assert {:ok, [replacement]} = Attachments.list_attachments(keeper, 73, Bill, bill.id)
    assert replacement.file_name == "invoice-2.txt"
    refute has_element?(view, "#payables-bill-attachments-#{attachment.id}")

    view |> element("#payables-bill-attachments-#{replacement.id}-remove") |> render_click()

    view
    |> form("#payables-bill-attachments-#{replacement.id}-remove-form", removal: %{reason: "wrong party"})
    |> render_submit()

    assert {:ok, []} = Attachments.list_attachments(keeper, 73, Bill, bill.id)
    assert has_element?(view, "#payables-bill-attachments-notice", "removed")
    assert {:ok, %{status: "removed"}} = Attachments.get_attachment(keeper, 73, replacement.id)
  end

  test "an approved bill's files show without replace or remove", %{conn: conn, keeper: keeper, bill: bill} do
    {:ok, attachment} = Attachments.attach(keeper, 73, Bill, bill.id, AttachmentsFixtures.file("invoice.txt"))
    {:ok, scope} = Tenancy.scope(41)
    approver = TestFixtures.sign_in!(scope, 73, 93, Bilimbi.Finance.Payables.PayablesCase.all_capabilities())
    {:ok, _approved} = Payables.approve_document(approver, 73, bill.id)
    grant_capabilities!([@view, @ledger_view, @attachments_view, @attachments_create, @attachments_delete])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{bill.id}")

    assert has_element?(view, "#payables-bill-attachments-#{attachment.id}")
    refute has_element?(view, "#payables-bill-attachments-#{attachment.id}-replace")
    refute has_element?(view, "#payables-bill-attachments-#{attachment.id}-remove")
    assert has_element?(view, "#payables-bill-attachments-form")
  end
end
