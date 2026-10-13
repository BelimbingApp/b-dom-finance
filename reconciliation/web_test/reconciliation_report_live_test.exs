defmodule BilimbiWeb.FinanceReconciliationReportLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Reconciliation.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Reconciliation

  @view "finance.reconciliation.view"
  @manage "finance.reconciliation.reconciliations.manage"
  @finalise "finance.reconciliation.reconciliations.finalise"
  @post "finance.reconciliation.statement-lines.post"
  @ledger_view "finance.ledger.view"
  @ledger_post "finance.ledger.entries.post"

  setup do
    signed_in_identity!()
    scene = Helpers.setup_scene!()
    deposit = Helpers.bank_entry!(scene, ~D[2026-10-01], "1000")

    statement =
      Helpers.import!(scene, [
        ["2026-10-01", "Deposit", "", "1000.00", "1000.00"],
        ["2026-10-20", "Monthly fee", "", "-5.00", "995.00"]
      ])

    [deposit_line, fee_line] = statement.lines

    {:ok, _match} =
      Reconciliation.match(scene.operator, 73, scene.bank_account.id, %{
        statement_line_ids: [deposit_line.id],
        entry_ids: [deposit.id]
      })

    {:ok, reconciliation} =
      Reconciliation.open_reconciliation(scene.operator, 73, scene.bank_account.id, %{
        end_date: ~D[2026-10-31],
        statement_balance: "995.00"
      })

    Map.merge(scene, %{fee_line: fee_line, reconciliation: reconciliation})
  end

  test "shows the figures and items, and withholds finalising without the grant",
       %{conn: conn} = scene do
    grant_capabilities!([@view, @ledger_view])

    {:ok, view, _html} =
      conn
      |> log_in_as()
      |> live(~p"/finance/reconciliation/reconciliations/#{scene.reconciliation.id}")

    assert has_element?(view, "#reconciliation-status", "open")
    assert has_element?(view, "#figure-statement-balance", "995.00 XTS")
    assert has_element?(view, "#figure-book-balance", "1,000.00")
    assert has_element?(view, "#figure-difference", "0.00")
    assert has_element?(view, "#figure-difference", "explained")
    assert has_element?(view, "#item-1", "Monthly fee")
    assert has_element?(view, "#item-1", "On the statement, not in the books")
    assert has_element?(view, "#reconciliation-finalise-forbidden", "finalise reconciliations")
    refute has_element?(view, "#item-#{scene.fee_line.id}-post-charge")
  end

  test "posts a bank charge from the page, follows the books, and finalises at zero",
       %{conn: conn} = scene do
    grant_capabilities!([@view, @manage, @finalise, @post, @ledger_view, @ledger_post])

    {:ok, view, _html} =
      conn
      |> log_in_as()
      |> live(~p"/finance/reconciliation/reconciliations/#{scene.reconciliation.id}")

    # A stray entry in the books that is not on the statement: the
    # difference stays explained (the entry is in transit), and the page
    # reads again on the ledger's notice.
    stray = Helpers.bank_entry!(scene, ~D[2026-10-25], "7")
    send(view.pid, {:finance_ledger_posted, %{company_id: 73, entry_number: stray.entry_number}})
    assert has_element?(view, "#reconciliation-items-table", "Entry #{stray.entry_number}")
    assert has_element?(view, "#figure-book-balance", "1,007.00")

    html = view |> element("#item-#{scene.fee_line.id}-post-charge") |> render_click()
    assert html =~ "and matched."
    refute has_element?(view, "#reconciliation-items-table", "Monthly fee")
    assert has_element?(view, "#figure-book-balance", "1,002.00")
    assert has_element?(view, "#figure-difference", "0.00")

    view |> element("#reconciliation-finalise") |> render_click()
    assert has_element?(view, "#reconciliation-status", "finalised")
    assert has_element?(view, "#reconciliation-through", "through entry 3")
    assert has_element?(view, "#reconciliation-events-table", "Finalised")
    refute has_element?(view, "#reconciliation-finalise")

    # The finalised figures stay as they were, whatever posts later.
    later = Helpers.bank_entry!(scene, ~D[2026-10-26], "50")
    send(view.pid, {:finance_ledger_posted, %{company_id: 73, entry_number: later.entry_number}})
    assert has_element?(view, "#figure-book-balance", "1,002.00")

    {:ok, %{status: "finalised", events: [_, %{recorded_by_user_id: 91, difference: zero}]}} =
      Reconciliation.get_reconciliation(scene.operator, 73, scene.reconciliation.id)

    assert Decimal.equal?(zero, 0)
  end

  test "refuses to let whoever opened a reconciliation finalise it", %{conn: conn} = scene do
    grant_capabilities!([@view, @manage, @finalise, @post, @ledger_view, @ledger_post])

    {:ok, _} =
      Reconciliation.abandon_reconciliation(scene.operator, 73, scene.reconciliation.id, %{
        reason: "Redo"
      })

    {:ok, scope} = Bilimbi.Base.Tenancy.scope(41)
    opener = Bilimbi.Finance.Reconciliation.TestFixtures.sign_in!(scope, 73, 91, [@manage])

    {:ok, own} =
      Reconciliation.open_reconciliation(opener, 73, scene.bank_account.id, %{
        end_date: ~D[2026-10-31],
        statement_balance: "995.00"
      })

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/reconciliation/reconciliations/#{own.id}")

    view |> element("#item-#{scene.fee_line.id}-post-charge") |> render_click()
    view |> element("#reconciliation-finalise") |> render_click()

    assert has_element?(view, "#flash-error", "separates duties")
    assert has_element?(view, "#reconciliation-status", "open")
  end

  test "refuses to finalise a difference and abandons with a reason", %{conn: conn} = scene do
    grant_capabilities!([@view, @manage, @finalise, @ledger_view])

    {:ok, _} =
      Reconciliation.abandon_reconciliation(scene.operator, 73, scene.reconciliation.id, %{
        reason: "Redo"
      })

    {:ok, wrong} =
      Reconciliation.open_reconciliation(scene.operator, 73, scene.bank_account.id, %{
        end_date: ~D[2026-10-31],
        statement_balance: "990.00"
      })

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/reconciliation/reconciliations/#{wrong.id}")

    assert has_element?(view, "#figure-difference", "-5.00")
    assert has_element?(view, "#figure-difference", "not yet explained")
    assert has_element?(view, "#reconciliation-finalise[disabled]")

    view |> element("#reconciliation-abandon") |> render_click()

    html =
      view
      |> form("#abandon-form", abandon: %{reason: "Typed the wrong balance"})
      |> render_submit()

    assert html =~ "The reconciliation was abandoned."
    assert has_element?(view, "#reconciliation-status", "abandoned")
    assert has_element?(view, "#reconciliation-events-table", "Typed the wrong balance")
  end
end
