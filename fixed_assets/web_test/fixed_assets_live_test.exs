defmodule BilimbiWeb.FixedAssetsLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.{FixedAssets, Ledger, Payables}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures

  setup do
    signed_in_identity!()
    Ledger.TestFixtures.create_ledger_tables!()
    Payables.TestFixtures.create_payables_tables!()
    Fixtures.create_tables!()
    {:ok, scope} = Tenancy.scope(41)
    keeper = Payables.TestFixtures.sign_in!(scope, 73, 92, Fixtures.capabilities())
    context = Fixtures.prepare_book!(keeper)
    Map.put(context, :scope, scope)
  end

  defp reader!(scope, caps), do: Payables.TestFixtures.sign_in!(scope, 73, 91, caps)

  test "register route requires view permission", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/fixed-assets/register")
  end

  test "register shows amounts, reconciliation, as-of control and link to schedule", c do
    asset = Fixtures.acquisition!(c)
    reader!(c.scope, [FixedAssets.view_capability(), Ledger.view_capability()])
    {:ok, view, _} = c.conn |> log_in_as() |> live(~p"/finance/fixed-assets/register")
    assert has_element?(view, "#assets-register-table")
    assert has_element?(view, "#assets-reconciliation")
    assert has_element?(view, "#assets-report-period")
    assert has_element?(view, "#assets-write-withheld")
    refute has_element?(view, "#assets-write-form")

    {:ok, detail, _} =
      c.conn |> log_in_as() |> live(~p"/finance/fixed-assets/register/#{asset.id}")

    assert has_element?(detail, "#asset-schedule")
    assert has_element?(detail, "#asset-dispose-withheld")
  end

  test "category defaults can be recorded and grants are rechecked after mount", c do
    reader!(c.scope, [
      FixedAssets.view_capability(),
      FixedAssets.configure_capability(),
      Ledger.view_capability()
    ])

    {:ok, view, _} = c.conn |> log_in_as() |> live(~p"/finance/fixed-assets/categories")
    assert has_element?(view, "#assets-write-form")

    attrs =
      Fixtures.category_attrs(c.accounts)
      |> Map.put(:name, "Second category")
      |> Map.new(fn {key, value} -> {Atom.to_string(key), to_string(value)} end)

    view |> form("#assets-write-form", asset: attrs) |> render_submit()
    {:ok, categories} = FixedAssets.list_categories(c.keeper, 73)
    assert length(categories) == 2

    {:ok, :stored} =
      Bilimbi.Base.Authz.put_principal_capability(
        c.scope,
        73,
        :user,
        91,
        FixedAssets.configure_capability(),
        false
      )

    view |> form("#assets-write-form", asset: %{attrs | "name" => "Refused"}) |> render_submit()
    assert has_element?(view, "#assets-write-withheld")
    assert {:ok, ^categories} = FixedAssets.list_categories(c.keeper, 73)
  end

  test "monthly run form posts a charge, repeated submission keeps one run", c do
    Fixtures.acquisition!(c)
    reader!(c.scope, Fixtures.capabilities())
    {:ok, view, _} = c.conn |> log_in_as() |> live(~p"/finance/fixed-assets/runs")

    for _ <- 1..2,
        do: view |> form("#assets-write-form", asset: %{period: "2026-01-01"}) |> render_submit()

    assert {:ok, [run]} = FixedAssets.list_runs(c.keeper, 73)
    assert Decimal.eq?(run.total, 100)
    assert has_element?(view, "#assets-runs-table")

    view
    |> form("#assets-reverse-form",
      asset: %{run_id: run.id, effective_date: "2026-02-01", reason: "Correct charge"}
    )
    |> render_submit()

    assert {:ok, [%{reversed?: true}]} = FixedAssets.list_runs(c.keeper, 73)
  end

  test "detail disposes and reverses the asset through the facade", c do
    asset = Fixtures.acquisition!(c)
    reader!(c.scope, Fixtures.capabilities())
    {:ok, view, _} = c.conn |> log_in_as() |> live(~p"/finance/fixed-assets/register/#{asset.id}")

    view
    |> form("#asset-dispose-form",
      asset: %{effective_date: "2026-01-01", proceeds: "0", reason: "Write off"}
    )
    |> render_submit()

    {:ok, detail} = FixedAssets.get_asset(c.keeper, 73, asset.id)
    assert [%{action: "disposed"}] = detail.events

    view
    |> form("#asset-reverse-form",
      asset: %{effective_date: "2026-01-02", reason: "Correct disposal"}
    )
    |> render_submit()

    {:ok, detail} = FixedAssets.get_asset(c.keeper, 73, asset.id)
    assert Enum.map(detail.events, & &1.action) == ["disposed", "disposal_reversed"]
  end
end
