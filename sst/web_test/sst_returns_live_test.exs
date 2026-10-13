defmodule BilimbiWeb.FinanceSstReturnsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Sst
  alias Bilimbi.Finance.Sst.PageFixtures, as: Helpers

  @view "finance.sst.view"
  @prepare "finance.sst.returns.sst-prepare"

  setup do
    signed_in_identity!()
    Helpers.setup_scene!()
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/sst")
  end

  test "lists the taxable periods and returns, and withholds preparing without the grant",
       %{conn: conn, operator: operator} do
    {:ok, tax_return} =
      Sst.open_return(operator, 73, %{tax_type: "sales_tax", period_start: ~D[2026-01-01]})

    grant_capabilities!([@view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/sst")

    assert has_element?(view, "#sst-periods", "Sales tax")
    assert has_element?(view, "#sst-periods", "Service tax")
    assert has_element?(view, "#return-#{tax_return.return_number}", "open")
    assert has_element?(view, "#sst-prepare-forbidden", "prepare SST returns")
    refute has_element?(view, "#sst-prepare-form")
  end

  test "prepares a return and opens its page", %{conn: conn} do
    grant_capabilities!([@view, @prepare | Helpers.reading_capabilities()])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/sst")

    assert {:error, {:live_redirect, %{to: path}}} =
             view
             |> form("#sst-prepare-form",
               prepare: %{tax_type: "service_tax", period_start: "2026-03-01"}
             )
             |> render_submit()

    assert path =~ ~r{^/finance/sst/returns/\d+$}

    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/sst")

    view
    |> form("#sst-prepare-form", prepare: %{tax_type: "service_tax", period_start: "2026-03-02"})
    |> render_submit()

    assert render(view) =~ "does not start a taxable period"
  end
end
