defmodule BilimbiWeb.FinanceSstSetupLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Authz
  alias Bilimbi.Finance.Sst
  alias Bilimbi.Finance.Sst.PageFixtures, as: Helpers

  @view "finance.sst.view"
  @manage "finance.sst.settings.manage"

  setup do
    signed_in_identity!()
    Helpers.setup_scene!()
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/sst/setup")
  end

  test "shows the registration, its history, and every tax code, and withholds changes without the grant",
       %{conn: conn} do
    grant_capabilities!([@view | Helpers.reading_capabilities()])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/sst/setup")

    assert has_element?(view, "#sst-sales-tax-number", "X00-2601-00000001")
    assert has_element?(view, "#sst-cycle", "2 months, the first from 2026-01-01")
    assert has_element?(view, "#sst-basis", "when payment is received")
    assert has_element?(view, "#registration-1", "user 92")
    assert has_element?(view, "#sst-registration-manage-forbidden", "change the SST registration")
    refute has_element?(view, "#sst-registration-form")
    assert has_element?(view, "#sst-tax-codes-table", "G10")
    assert has_element?(view, "#sst-tax-codes-table", "unmapped")
    refute has_element?(view, "#sst-mapping-form")
  end

  test "records a new registration version and maps a tax code, each with its reason",
       %{conn: conn, codes: codes} = scene do
    grant_capabilities!([@view, @manage | Helpers.reading_capabilities()])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/sst/setup")

    view
    |> form("#sst-registration-form",
      registration: %{service_tax_number: "X00-2601-00000005", reason: "New number"}
    )
    |> render_submit()

    assert has_element?(view, "#sst-service-tax-number", "X00-2601-00000005")
    assert has_element?(view, "#registration-2", "New number")

    view
    |> form("#sst-registration-form", registration: %{sales_tax_number: "not a number"})
    |> render_submit()

    assert render(view) =~ "is not shaped like A00-0000-00000000"

    view
    |> form("#sst-mapping-form",
      mapping: %{tax_code: "receivables:#{codes.goods10.id}", box: "11b", reason: "Ten percent"}
    )
    |> render_submit()

    assert has_element?(view, "#tax-code-receivables-#{codes.goods10.id}", "Sales tax 11(b)")
    assert has_element?(view, "#mapping-1", "Ten percent")

    # The page re-asks the capability on every event.
    {:ok, :stored} =
      Authz.put_principal_capability(scene.scope, 73, :user, 91, @manage, false)

    view
    |> form("#sst-mapping-form",
      mapping: %{tax_code: "receivables:#{codes.goods5.id}", box: "11a"}
    )
    |> render_submit()

    assert {:ok, [_only]} = Sst.list_mappings(scene.operator, 73)
  end
end
