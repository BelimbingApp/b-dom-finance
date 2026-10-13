defmodule BilimbiWeb.FinanceApprovalExceptionsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures

  @page "/finance/reports/approval-exceptions"
  @view "finance.ledger.view"
  @separation "finance.ledger.duty-separation.manage"
  @review "finance.ledger.approval-exceptions.review"

  setup do
    signed_in_identity!()
    LedgerFixtures.create_ledger_tables!()
    {:ok, system} = Tenancy.scope(41)

    # Another user keeps the books, so the signed-in user 91 holds only what
    # each test grants.
    clerk = LedgerFixtures.sign_in!(system, 73, 92, [@view, @separation])
    %{system: system, clerk: clerk}
  end

  defp self_approval!(scope, subject_id) do
    :ok =
      Ledger.check_approval(scope, 73, %{
        source: "finance/payables",
        action: "document_approval",
        subject_type: "bill",
        subject_id: subject_id,
        subject: "Bill INV-#{subject_id} from Party one, 5 XTS",
        prepared_by: [%{user_id: 92}]
      })
  end

  test "refuses the page without the ledger view grant", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} = conn |> log_in_as() |> live(@page)
  end

  test "lists same-person approvals for an independent reviewer to record", context do
    %{conn: conn, clerk: clerk} = context
    grant_capabilities!([@view, @review])
    {:ok, _} = Ledger.set_duty_separation(clerk, 73, %{required: false, reason: "One clerk"})
    self_approval!(clerk, 7)
    self_approval!(clerk, 8)

    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    assert has_element?(view, "#duty-separation-status", "Not required")
    assert has_element?(view, "#duty-separation-changes", "One clerk")
    refute has_element?(view, "#duty-separation-change")
    assert has_element?(view, "#exception-1", "Same person")
    assert has_element?(view, "#exception-1", "Payables: Document approved")
    assert has_element?(view, "#exception-1", "Bill INV-7 from Party one")
    assert has_element?(view, "#exception-1", "User #92")

    view |> element("#exception-review-open-1") |> render_click()
    assert has_element?(view, "#exception-review-modal")

    view
    |> form("#exception-review-form", dialog: %{text: "Invoice and delivery checked"})
    |> render_submit()

    assert has_element?(view, "#flash-success", "Review of exception 1 recorded")
    assert has_element?(view, "#exception-review-1", "User #91")
    assert has_element?(view, "#exception-review-1", "Invoice and delivery checked")
    refute has_element?(view, "#exception-review-open-1")

    view |> element("#exceptions-review a", "Awaiting review") |> render_click()
    refute has_element?(view, "#exception-1")
    assert has_element?(view, "#exception-2")
  end

  test "refuses a review by whoever approved it", context do
    %{conn: conn, system: system} = context
    grant_capabilities!([@view, @review, @separation])
    me = LedgerFixtures.sign_in!(system, 73, 91, [@view])
    {:ok, _} = Ledger.set_duty_separation(me, 73, %{required: false, reason: "One clerk"})

    :ok =
      Ledger.check_approval(me, 73, %{
        source: "finance/ledger",
        action: "journal_approval",
        subject_type: "journal",
        subject_id: 3,
        subject: "Journal 3: Accrual",
        prepared_by: [%{user_id: 91}]
      })

    {:ok, view, _html} = conn |> log_in_as() |> live(@page)
    view |> element("#exception-review-open-1") |> render_click()
    view |> form("#exception-review-form", dialog: %{text: ""}) |> render_submit()

    assert has_element?(view, "#flash-error", "neither approved nor prepared")
    assert has_element?(view, "#exception-review-open-1")
  end

  test "turns separation off with a reason and requires it again", %{conn: conn} do
    grant_capabilities!([@view, @separation])
    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    assert has_element?(view, "#duty-separation-status", "Required")
    assert has_element?(view, "#exceptions-empty")

    view |> element("#duty-separation-change") |> render_click()
    view |> form("#duty-separation-form", dialog: %{text: " "}) |> render_submit()
    assert has_element?(view, "#flash-error", "Give a reason")

    view
    |> form("#duty-separation-form", dialog: %{text: "Only one finance person"})
    |> render_submit()

    assert has_element?(view, "#flash-success", "Separation of duties is off")
    assert has_element?(view, "#duty-separation-status", "Not required")
    assert has_element?(view, "#duty-separation-changes", "Only one finance person")

    view |> element("#duty-separation-change") |> render_click()
    view |> form("#duty-separation-form", dialog: %{text: ""}) |> render_submit()
    assert has_element?(view, "#duty-separation-status", "Required")
    assert has_element?(view, "#duty-separation-change-2", "Required")
  end
end
