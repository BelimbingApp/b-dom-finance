defmodule BilimbiWeb.FinanceReconciliationBankAccountsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Reconciliation.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Reconciliation

  @view "finance.reconciliation.view"
  @manage "finance.reconciliation.bank-accounts.manage"
  @ledger_view "finance.ledger.view"

  setup do
    signed_in_identity!()
    Helpers.setup_scene!()
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/reconciliation")
  end

  test "lists the bank accounts and withholds the form without the manage grant", %{
    conn: conn,
    bank_account: account
  } do
    grant_capabilities!([@view, @ledger_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/reconciliation")

    assert has_element?(view, "#bank-account-#{account.id}", "Operating account")
    assert has_element?(view, "#bank-account-#{account.id}", "1010 Account 1010")
    assert has_element?(view, "#bank-accounts-manage-forbidden", "add or change bank accounts")
    refute has_element?(view, "#bank-account-form")
  end

  test "adds a bank account with its mapping and changes one with a logged reason", %{
    conn: conn,
    accounts: accounts,
    operator: operator,
    bank_account: account
  } do
    grant_capabilities!([@view, @manage, @ledger_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/reconciliation")

    view
    |> form("#bank-account-form",
      bank_account: %{
        name: "Savings",
        ledger_account_id: accounts.other_bank.id,
        header_rows: "0",
        date: "1",
        date_format: "DD/MM/YYYY",
        description: "2",
        amount: "",
        debit: "3",
        credit: "4",
        delimiter: ";"
      }
    )
    |> render_submit()

    assert has_element?(view, "#bank-accounts-table", "Savings")
    {:ok, [_operating, savings]} = Reconciliation.list_bank_accounts(operator, 73)
    assert savings.import_mapping["debit"] == 3
    assert savings.import_mapping["date_format"] == "DD/MM/YYYY"

    # A mapping the facade refuses is shown on the form.
    html =
      view
      |> form("#bank-account-form",
        bank_account: %{
          name: "Broken",
          ledger_account_id: accounts.other_bank.id,
          date: "Date",
          description: "D"
        }
      )
      |> render_submit()

    assert html =~ "needs an amount column"

    view |> element("#bank-account-#{account.id}-edit") |> render_click()
    assert has_element?(view, "#bank-account-form-heading", "Change Operating account")
    assert has_element?(view, "#bank-account-ledger-account-fixed", "never changes")

    view
    |> form("#bank-account-form",
      bank_account: %{match_window_days: "9", reason: "Bank posts late"}
    )
    |> render_submit()

    assert has_element?(view, "#bank-account-#{account.id}", "9 days")
    {:ok, changes} = Reconciliation.list_bank_account_changes(operator, 73, account.id)

    assert Enum.any?(
             changes,
             &(&1.field == "match_window_days" and &1.new_value == "9" and
                 &1.reason == "Bank posts late" and &1.changed_by_user_id == 91)
           )

    view |> element("#bank-account-#{account.id}-toggle") |> render_click()
    assert has_element?(view, "#bank-account-#{account.id}", "inactive")
  end
end
