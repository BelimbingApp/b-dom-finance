defmodule BilimbiWeb.FinanceReconciliationImportLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Reconciliation.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.TestFixtures

  @view "finance.reconciliation.view"
  @import "finance.reconciliation.statements.import"
  @open "finance.reconciliation.reconciliations.manage"
  @ledger_view "finance.ledger.view"

  @rows [
    ["2026-10-01", "Deposit", "DEP-1", "1000.00", "1000.00"],
    ["2026-10-20", "Monthly fee", "", "-5.00", "995.00"]
  ]

  setup do
    signed_in_identity!()
    Helpers.setup_scene!()
  end

  defp upload(view, name, rows) do
    view
    |> file_input("#statement-import-form", :statement, [
      %{name: name, content: TestFixtures.csv(rows), type: "text/csv"}
    ])
    |> render_upload(name)

    view |> form("#statement-import-form") |> render_submit()
  end

  test "withholds the import form without the import grant", %{conn: conn, bank_account: account} do
    grant_capabilities!([@view, @ledger_view])

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/reconciliation/accounts/#{account.id}")

    assert has_element?(view, "#statement-import-forbidden", "import statements")
    assert has_element?(view, "#statements-table-empty", "No statements yet")
  end

  test "imports a statement from the uploaded file and refuses it a second time", %{
    conn: conn,
    bank_account: account,
    operator: operator
  } do
    grant_capabilities!([
      @view,
      @import,
      @open,
      @ledger_view,
      "finance.attachments.view",
      "finance.attachments.create"
    ])

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/reconciliation/accounts/#{account.id}")

    html = upload(view, "october.csv", @rows)
    assert html =~ "Statement 1 imported: 2 lines from 2026-10-01 to 2026-10-20."

    {:ok, [statement]} = Reconciliation.list_statements(operator, 73, account.id)
    assert statement.imported_by_user_id == 91
    assert has_element?(view, "#statement-#{statement.id}", "october.csv")
    assert has_element?(view, "#statement-#{statement.id}-file[href$='/download']", "october.csv")
    assert has_element?(view, "#statement-#{statement.id}", "995.00")

    html = upload(view, "again.csv", @rows)
    assert html =~ "This file was already imported as statement 1."

    html =
      upload(view, "overlap.csv", [
        List.last(@rows),
        ["2026-10-21", "Interest", "", "1.00", "996.00"]
      ])

    assert html =~ "Nothing was imported: 1 lines are already on file"
    assert {:ok, [_one]} = Reconciliation.list_statements(operator, 73, account.id)

    # The next reconciliation is suggested at the statement's end and balance.
    assert has_element?(view, "#reconciliation-end-date[value='2026-10-20']")
    assert has_element?(view, "#reconciliation-statement-balance[value='995']")
  end

  test "opens a reconciliation from the statement's end",
       %{conn: conn, bank_account: account} = scene do
    grant_capabilities!([@view, @open, @ledger_view])
    Helpers.import!(scene, @rows)

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/reconciliation/accounts/#{account.id}")

    result =
      view
      |> form("#reconciliation-open-form",
        reconciliation: %{end_date: "2026-10-31", statement_balance: "995.00"}
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: "/finance/reconciliation/reconciliations/" <> _id}}} =
             result

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/reconciliation/accounts/#{account.id}")

    assert has_element?(view, "#reconciliations-table", "Reconciliation 1")
    assert has_element?(view, "#reconciliations-table", "open")

    html =
      view
      |> form("#reconciliation-open-form",
        reconciliation: %{end_date: "2026-11-30", statement_balance: "1"}
      )
      |> render_submit()

    assert html =~ "already has an open reconciliation"
  end
end
