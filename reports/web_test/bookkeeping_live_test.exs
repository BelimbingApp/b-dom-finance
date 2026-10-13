defmodule BilimbiWeb.FinanceBookkeepingLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures

  @page "/finance/reports/bookkeeping"
  @view "finance.ledger.view"
  @controlled "finance.ledger.controlled-bookkeeping.manage"
  @periods "finance.ledger.periods.manage"
  @review "finance.ledger.late-recordings.review"

  setup do
    signed_in_identity!()
    LedgerFixtures.create_ledger_tables!()
    {:ok, system} = Tenancy.scope(41)

    # Another user keeps the books, so the signed-in user 91 holds only what
    # each test grants.
    keeper =
      LedgerFixtures.sign_in!(system, 73, 92, [
        @view,
        @controlled,
        @periods,
        "finance.ledger.accounts.manage",
        "finance.ledger.entries.post"
      ])

    {:ok, _book} = Ledger.open_book(keeper, 73, %{currency_code: "XTS", minor_units: 2})
    %{system: system, keeper: keeper}
  end

  test "refuses the page without the ledger view grant", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} = conn |> log_in_as() |> live(@page)
  end

  test "a new company is controlled and must open its first fiscal year", %{conn: conn} do
    grant_capabilities!([@view, @controlled, @periods])
    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    assert has_element?(view, "#controlled-bookkeeping-status", "Controlled")
    assert has_element?(view, "#no-fiscal-year", "No fiscal year is open")
    assert has_element?(view, "#fiscal-year-open", "Open the first fiscal year")

    view |> element("#fiscal-year-open") |> render_click()
    assert has_element?(view, "#fiscal-year-modal")

    view
    |> form("#fiscal-year-form", dialog: %{start_date: "2026-01-01", end_date: ""})
    |> render_submit()

    assert has_element?(view, "#flash-success", "Fiscal year 2026-01-01 to 2026-12-31 is open")
    refute has_element?(view, "#no-fiscal-year")
    assert has_element?(view, "#fiscal-year-open", "Open the next fiscal year")
  end

  test "a blank first day opens no first fiscal year", %{conn: conn} do
    grant_capabilities!([@view, @controlled, @periods])
    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    view |> element("#fiscal-year-open") |> render_click()

    view
    |> form("#fiscal-year-form", dialog: %{start_date: "", end_date: ""})
    |> render_submit()

    assert has_element?(
             view,
             "#flash-error",
             "Give the first day of the fiscal year as a date."
           )

    assert has_element?(view, "#no-fiscal-year")
  end

  test "a malformed last day opens no fiscal year and keeps the page up", %{conn: conn} do
    grant_capabilities!([@view, @controlled, @periods])
    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    view |> element("#fiscal-year-open") |> render_click()

    view
    |> form("#fiscal-year-form", dialog: %{start_date: "2026-01-01", end_date: "not-a-date"})
    |> render_submit()

    assert has_element?(view, "#flash-error", "must be a date")
    assert has_element?(view, "#no-fiscal-year")
  end

  test "turning controlled bookkeeping off needs a reason, and on again needs none", %{
    conn: conn
  } do
    grant_capabilities!([@view, @controlled])
    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    view |> element("#controlled-bookkeeping-off") |> render_click()
    assert has_element?(view, "#controlled-off-modal")

    view
    |> form("#controlled-off-form", dialog: %{text: "Migrating from a legacy system"})
    |> render_submit()

    assert has_element?(view, "#flash-success", "Bookkeeping is not controlled")
    assert has_element?(view, "#controlled-bookkeeping-status", "Not controlled")
    assert has_element?(view, "#controlled-bookkeeping-changes", "Migrating from a legacy system")

    view |> element("#controlled-bookkeeping-on") |> render_click()
    assert has_element?(view, "#controlled-bookkeeping-status", "Controlled")
  end

  test "lists entries recorded late, and records an independent reviewer's reason", %{
    conn: conn,
    keeper: keeper
  } do
    # Two years, so an entry dated 100 days back falls in an open period.
    today = Date.utc_today()

    {:ok, _year} =
      Ledger.open_fiscal_year(keeper, 73, %{
        start_date: Date.new!(today.year - 1, 1, 1),
        end_date: Date.new!(today.year, 12, 31)
      })

    {:ok, cash} =
      Ledger.create_account(keeper, 73, %{code: "1000", name: "Cash", account_type: "asset"})

    {:ok, income} =
      Ledger.create_account(keeper, 73, %{code: "4000", name: "Sales", account_type: "income"})

    {:ok, late} =
      Ledger.post_entry(keeper, 73, %{
        entry_date: Date.add(Date.utc_today(), -100),
        description: "Old sale",
        lines: [%{account_id: cash.id, debit: "10"}, %{account_id: income.id, credit: "10"}]
      })

    grant_capabilities!([@view, @review])
    {:ok, view, _html} = conn |> log_in_as() |> live(@page)

    assert has_element?(view, "#late-recordings-table", "Old sale")
    assert has_element?(view, "#late-recordings-table", "Late")
    assert has_element?(view, "#late-entry-#{late.entry_number}", "User #92")

    view |> element("#late-entry-review-open-#{late.entry_number}") |> render_click()
    assert has_element?(view, "#late-review-modal")

    view
    |> form("#late-review-form", dialog: %{text: "Supplier invoice arrived late"})
    |> render_submit()

    assert has_element?(view, "#flash-success", "Review of entry #{late.id} recorded")
    assert has_element?(view, "#late-entry-review-#{late.entry_number}", "Supplier invoice")
    refute has_element?(view, "#late-entry-review-open-#{late.entry_number}")
  end
end
