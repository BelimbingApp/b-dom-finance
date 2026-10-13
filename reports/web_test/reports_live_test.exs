defmodule BilimbiWeb.FinanceReportsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reports.TestFixtures

  @october "/finance/reports?period=custom&from=2026-10-01&to=2026-10-31"

  setup do
    signed_in_identity!()
    LedgerFixtures.create_ledger_tables!()
    {:ok, system} = Tenancy.scope(41)
    %{system: system}
  end

  test "refuses the page without the ledger view grant", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/reports")
  end

  test "says so when the company's book is not open", %{conn: conn} do
    grant_capabilities!(["finance.ledger.view"])
    {:ok, view, _html} = conn |> log_in_as() |> live(@october)
    assert has_element?(view, "#report-refusal", "not open")
  end

  describe "with postings" do
    setup %{system: system} do
      operator =
        LedgerFixtures.sign_in!(system, 73, 91, [
          "finance.ledger.view",
          "finance.ledger.accounts.manage",
          "finance.ledger.entries.post"
        ])

      {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
      Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(operator, 73)
      accounts = TestFixtures.chart!(operator, 73)

      for {date, lines} <- [
            {~D[2026-09-15], [{"1010", :debit, "1000"}, {"3000", :credit, "1000"}]},
            {~D[2026-10-03], [{"1020", :debit, "300"}, {"4000", :credit, "300"}]},
            {~D[2026-10-10], [{"5000", :debit, "120"}, {"2000", :credit, "120"}]}
          ] do
        TestFixtures.post!(operator, accounts, date, lines)
      end

      %{operator: operator, accounts: accounts}
    end

    test "refuses an auditor export without its separate grant", %{conn: conn} do
      {:ok, view, _html} = conn |> log_in_as() |> live(@october)
      view |> element("#export-auditor-pack") |> render_click()
      assert has_element?(view, "[role=alert]", "permission")
      refute has_element?(view, "#download-auditor-pack")
    end

    test "shows the headline figures and reads again when an entry posts", context do
      %{conn: conn, operator: operator, accounts: accounts} = context
      {:ok, view, _html} = conn |> log_in_as() |> live(@october)

      assert has_element?(view, "#overview-figure-income", "300.00")
      assert has_element?(view, "#overview-figure-net-income", "180.00")
      assert has_element?(view, "#overview-figure-assets", "1,300.00")
      assert has_element?(view, "#report-through", "through entry 3")

      entry =
        TestFixtures.post!(operator, accounts, ~D[2026-10-20], [
          {"1010", :debit, "1200.5"},
          {"4100", :credit, "1200.5"}
        ])

      # A sandboxed post never commits, so PostgreSQL never announces it; the
      # ledger's notice is what the page would receive after the commit.
      send(
        view.pid,
        {:finance_ledger_posted, %{company_id: 73, entry_number: entry.entry_number}}
      )

      assert has_element?(view, "#overview-figure-income", "1,500.50")
      assert has_element?(view, "#report-through", "through entry 4")
    end

    test "a pinned report keeps its figures when an entry posts", context do
      %{conn: conn, operator: operator, accounts: accounts} = context
      {:ok, view, _html} = conn |> log_in_as() |> live(@october)

      view |> element("#pin-report") |> render_click()
      assert has_element?(view, "#unpin-report")

      TestFixtures.post!(operator, accounts, ~D[2026-10-20], [
        {"1010", :debit, "5"},
        {"4100", :credit, "5"}
      ])

      send(view.pid, {:finance_ledger_posted, %{company_id: 73, entry_number: 4}})
      assert has_element?(view, "#overview-figure-income", "300.00")
      assert has_element?(view, "#report-through", "through entry 3")

      view |> element("#unpin-report") |> render_click()
      assert has_element?(view, "#overview-figure-income", "305.00")
    end

    test "a balance sheet figure opens the entries behind it", context do
      %{conn: conn, accounts: accounts} = context
      conn = log_in_as(conn)
      {:ok, view, _html} = live(conn, @october <> "&view=balance-sheet")

      assert has_element?(view, "#balance-sheet-account-#{accounts["1020"].id}-0", "300.00")
      assert has_element?(view, "#balance-sheet-earnings", "180.00")
      assert has_element?(view, "#balance-sheet-asset-total", "1,300.00")
      assert has_element?(view, "#balance-sheet-total-liabilities-and-equity", "1,300.00")

      {:ok, activity, _html} =
        view
        |> element("#balance-sheet-account-#{accounts["1010"].id}-0")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(activity, "#activity-through", "through entry 3")
      assert has_element?(activity, "#activity-debits", "1,000.00")
      assert has_element?(activity, "#activity-entries", "Entry on 2026-09-15")
    end

    test "compares with the previous period until asked not to", %{conn: conn} do
      {:ok, view, _html} = conn |> log_in_as() |> live(@october <> "&view=profit-and-loss")

      assert has_element?(view, "#profit-and-loss th", "2026-09-01 – 2026-09-30")
      assert has_element?(view, "#profit-and-loss-net-income", "180.00")
      assert has_element?(view, "#profit-and-loss a[href*='closing=excluded']")

      view
      |> form("#report-compare", report: %{compare: "false"})
      |> render_change()

      refute has_element?(view, "#profit-and-loss th", "2026-09-01 – 2026-09-30")
    end

    test "lists the configured cash accounts", %{conn: conn} do
      {:ok, view, _html} = conn |> log_in_as() |> live(@october <> "&view=cash-position")
      assert has_element?(view, "#cash-position-card", "No cash accounts configured")

      TestFixtures.put_sections!([
        %{"report" => "cash_position", "name" => "Bank and cash", "accounts" => ["1000"]}
      ])

      {:ok, view, _html} = conn |> log_in_as() |> live(@october <> "&view=cash-position")
      assert has_element?(view, "#cash-position", "Bank and cash")
      assert has_element?(view, "#cash-position-cash-total", "1,300.00")
    end
  end
end
