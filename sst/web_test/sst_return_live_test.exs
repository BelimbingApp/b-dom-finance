defmodule BilimbiWeb.FinanceSstReturnLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Sst
  alias Bilimbi.Finance.Sst.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Sst.SstCase

  @view "finance.sst.view"
  @prepare "finance.sst.returns.sst-prepare"
  @finalise "finance.sst.returns.sst-finalise"
  @amend "finance.sst.returns.sst-amend"

  setup do
    signed_in_identity!()
    scene = Helpers.setup_scene!()
    _invoice = SstCase.invoice!(scene, ~D[2026-01-10], [SstCase.line(scene, "1000", :goods10)])

    {:ok, tax_return} =
      Sst.open_return(scene.operator, 73, %{tax_type: "sales_tax", period_start: ~D[2026-01-01]})

    Map.put(scene, :tax_return, tax_return)
  end

  test "shows what stops an open return finalising, and withholds finalising without the grant",
       %{conn: conn, tax_return: tax_return} do
    grant_capabilities!([@view | Helpers.reading_capabilities()])

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/sst/returns/#{tax_return.id}")

    assert has_element?(view, "#sst-return-status", "open")
    assert has_element?(view, "#sst-return-number", "X00-2601-00000001")
    assert has_element?(view, "#sst-return-due", "2026-03-31")
    assert has_element?(view, "#sst-return-blockers", "G10 has tax in the period")
    assert has_element?(view, "#box-14", "0.00")
    assert has_element?(view, "#sst-return-finalise-forbidden", "finalise SST returns")
    refute has_element?(view, "#sst-return-finalise")
    refute has_element?(view, "#sst-adjustment-form")
  end

  test "adjusts, finalises, and amends from the page, each re-asking its capability",
       %{conn: conn, tax_return: tax_return} = scene do
    SstCase.map_all!(scene)
    grant_capabilities!([@view, @prepare, @finalise, @amend | Helpers.reading_capabilities()])

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/sst/returns/#{tax_return.id}")

    refute has_element?(view, "#sst-return-blockers")
    assert has_element?(view, "#box-11b", "1,000.00")
    assert has_element?(view, "#box-11b", "100.00")
    assert has_element?(view, "#sst-return-accounts-table", "agrees")

    view
    |> form("#sst-adjustment-form",
      adjustment: %{box: "13d", tax_amount: "7", description: "Bad debt relief approved"}
    )
    |> render_submit()

    assert has_element?(view, "#adjustment-1", "Bad debt relief approved")
    assert has_element?(view, "#box-14", "93.00")

    # A document posted while the page is open is read on the ledger's notice.
    _late = SstCase.invoice!(scene, ~D[2026-02-10], [SstCase.line(scene, "100", :goods10)])
    send(view.pid, {:finance_ledger_posted, %{company_id: 73}})
    assert has_element?(view, "#box-14", "103.00")

    view |> element("#sst-return-finalise") |> render_click()
    assert has_element?(view, "#sst-return-status", "finalised v1")
    refute has_element?(view, "#sst-adjustment-form")

    # What posts afterwards is shown beside the finalised figures, not in them.
    _later = SstCase.invoice!(scene, ~D[2026-02-11], [SstCase.line(scene, "50", :goods10)])
    send(view.pid, {:finance_ledger_posted, %{company_id: 73}})
    assert has_element?(view, "#box-14", "103.00")
    assert has_element?(view, "#posted-since-11b", "50.00")

    view |> element("#sst-return-amend") |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} =
             view
             |> form("#sst-reason-form", reason: %{reason: "Invoice found late"})
             |> render_submit()

    {:ok, amendment, _html} = conn |> log_in_as() |> live(path)
    assert has_element?(amendment, "#sst-return-amends", "Invoice found late")
    assert has_element?(amendment, "#adjustment-2", "Bad debt relief approved")
    assert has_element?(amendment, "#box-11b", "1,150.00")
  end

  test "discards an open return with a reason", %{conn: conn, tax_return: tax_return} do
    grant_capabilities!([@view, @prepare | Helpers.reading_capabilities()])

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/sst/returns/#{tax_return.id}")

    view |> element("#sst-return-discard") |> render_click()
    view |> form("#sst-reason-form", reason: %{reason: "Wrong period"}) |> render_submit()

    assert has_element?(view, "#sst-return-status", "discarded")
    assert has_element?(view, "#sst-return-events-table", "Wrong period")
    refute has_element?(view, "#sst-return-items")
  end

  test "exports the return as CSV and as a printable page", %{conn: conn, tax_return: tax_return} do
    grant_capabilities!([@view | Helpers.reading_capabilities()])
    conn = log_in_as(conn)

    csv = get(conn, ~p"/finance/sst/returns/#{tax_return.id}/export.csv")
    assert csv.status == 200
    assert [content_type] = get_resp_header(csv, "content-type")
    assert content_type =~ "text/csv"
    assert csv.resp_body =~ "part,item,description,value,tax"
    assert csv.resp_body =~ "Draft, not finalised"

    page = get(conn, ~p"/finance/sst/returns/#{tax_return.id}/print")
    assert page.status == 200
    assert page.resp_body =~ "SST-02: Sales tax return"
    assert page.resp_body =~ "Draft: not finalised"

    assert get(conn, ~p"/finance/sst/returns/999999/export.csv").status == 404
  end
end
