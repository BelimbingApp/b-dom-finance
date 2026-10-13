defmodule BilimbiWeb.FinanceReconciliationMatchingLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Reconciliation.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Reconciliation

  @view "finance.reconciliation.view"
  @match "finance.reconciliation.matches.manage"
  @ledger_view "finance.ledger.view"

  setup do
    signed_in_identity!()
    scene = Helpers.setup_scene!()
    deposit = Helpers.bank_entry!(scene, ~D[2026-10-01], "1000", %{reference: "DEP-1"})
    half_one = Helpers.bank_entry!(scene, ~D[2026-10-04], "-30")
    half_two = Helpers.bank_entry!(scene, ~D[2026-10-04], "-30")

    statement =
      Helpers.import!(scene, [
        ["2026-10-01", "Deposit", "DEP-1", "1000.00", "1000.00"],
        ["2026-10-05", "Bill combined", "", "-60.00", "940.00"]
      ])

    [deposit_line, bill_line] = statement.lines

    Map.merge(scene, %{
      deposit: deposit,
      halves: [half_one, half_two],
      deposit_line: deposit_line,
      bill_line: bill_line
    })
  end

  test "shows both sides with suggestions and withholds the controls without the grant",
       %{conn: conn} = scene do
    grant_capabilities!([@view, @ledger_view])

    {:ok, view, _html} =
      conn
      |> log_in_as()
      |> live(~p"/finance/reconciliation/accounts/#{scene.bank_account.id}/matching")

    assert has_element?(view, "#line-#{scene.deposit_line.id}", "1,000.00")

    assert has_element?(
             view,
             "#line-#{scene.deposit_line.id}-suggestion",
             "Entry 1 on 2026-10-01"
           )

    assert has_element?(view, "#entry-#{scene.deposit.id}", "Entry on 2026-10-01")
    assert has_element?(view, "#matching-forbidden", "match statement lines")
    refute has_element?(view, "#line-#{scene.deposit_line.id}-accept")
    refute has_element?(view, "#match-selected-submit")
  end

  test "accepts a suggestion, matches a selection of many, and unmatches with a reason",
       %{conn: conn} = scene do
    grant_capabilities!([@view, @match, @ledger_view])

    {:ok, view, _html} =
      conn
      |> log_in_as()
      |> live(~p"/finance/reconciliation/accounts/#{scene.bank_account.id}/matching")

    html = view |> element("#line-#{scene.deposit_line.id}-accept") |> render_click()
    assert html =~ "Match 1 made: 1 statement line with 1 entry."
    refute has_element?(view, "#line-#{scene.deposit_line.id}")
    assert has_element?(view, "#standing-matches-table", "Suggested match")

    [half_one, half_two] = scene.halves

    view
    |> form("#matching-form", %{
      lines: [scene.bill_line.id],
      entries: [half_one.id, half_two.id],
      note: "Two halves"
    })
    |> render_change()

    assert has_element?(view, "#selected-lines-sum", "-60.00")
    assert has_element?(view, "#selected-entries-sum", "-60.00")

    html =
      view
      |> form("#matching-form", %{
        lines: [scene.bill_line.id],
        entries: [half_one.id, half_two.id],
        note: "Two halves"
      })
      |> render_submit()

    assert html =~ "Match 2 made: 1 statement line with 2 entries."
    assert has_element?(view, "#unmatched-lines-table-empty", "Every statement line is matched")
    assert has_element?(view, "#unmatched-entries-table-empty")

    {:ok, [first, second]} =
      Reconciliation.list_matches(scene.operator, 73, scene.bank_account.id)

    assert first.matched_by_user_id == 91 and second.note == "Two halves"

    view |> element("#match-#{second.id}-unmatch") |> render_click()
    html = view |> form("#unmatch-form", unmatch: %{reason: "Wrong bill"}) |> render_submit()
    assert html =~ "Match 2 unmatched"
    assert has_element?(view, "#line-#{scene.bill_line.id}")
    assert has_element?(view, "#entry-#{half_one.id}")

    {:ok, %{status: "unmatched", events: [_, %{reason: "Wrong bill", recorded_by_user_id: 91}]}} =
      Reconciliation.get_match(scene.operator, 73, second.id)

    # An unbalanced selection is refused with both sums.
    html =
      view
      |> form("#matching-form", %{lines: [scene.bill_line.id], entries: [half_one.id]})
      |> render_submit()

    assert html =~ "The sides do not agree"
  end
end
