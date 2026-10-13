defmodule BilimbiWeb.FinancePayrollSetupLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Payroll
  alias Bilimbi.Finance.Payroll.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Payroll.StubPeopleSource

  @view "finance.payroll.view"
  @manage "finance.payroll.settings.manage"
  @ledger_view "finance.ledger.view"

  setup do
    signed_in_identity!()
    on_exit(&StubPeopleSource.uninstall!/0)
    Helpers.setup_scene!(configured: false)
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/payroll/setup")
  end

  test "shows the accounts unset and withholds the forms without the manage grant", %{
    conn: conn
  } do
    grant_capabilities!([@view, @ledger_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll/setup")

    assert has_element?(view, "#payroll-settings")
    refute has_element?(view, "#payroll-settings-current")
    assert has_element?(view, "#payroll-settings-manage-forbidden")
    refute has_element?(view, "#payroll-settings-form")
    refute has_element?(view, "#payroll-mapping-form")
    assert has_element?(view, "#payroll-mappings-table")
  end

  test "sets the posting accounts and adds and changes a mapping, each with its logged reason",
       %{conn: conn, accounts: accounts, operator: operator} do
    grant_capabilities!([@view, @manage, @ledger_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll/setup")

    view
    |> form("#payroll-settings-form",
      settings: %{
        net_pay_account_id: accounts.net_pay.id,
        claims_payable_account_id: accounts.claims_payable.id,
        reason: "first setup"
      }
    )
    |> render_submit()

    assert has_element?(view, "#payroll-settings-net-pay", "2100 Account 2100")
    assert has_element?(view, "#payroll-settings-changes-table", "first setup")
    assert {:ok, %{net_pay_account_id: id}} = Payroll.get_settings(operator, 73)
    assert id == accounts.net_pay.id

    view
    |> form("#payroll-mapping-form",
      mapping: %{
        kind: "component",
        code: "basic",
        direction: "earning",
        expense_account_id: accounts.salaries.id,
        liability_account_id: ""
      }
    )
    |> render_submit()

    assert {:ok, [basic]} = Payroll.list_mappings(operator, 73)
    assert has_element?(view, "#payroll-mapping-#{basic.id}", "6000 Account 6000")

    # A claim category needs no direction; the form supplies `claim`.
    view
    |> form("#payroll-mapping-form",
      mapping: %{
        kind: "claim_category",
        code: "travel",
        expense_account_id: accounts.travel.id,
        liability_account_id: ""
      }
    )
    |> render_submit()

    # Mappings list by kind, then code: the claim category comes first.
    assert {:ok, [travel, _basic]} = Payroll.list_mappings(operator, 73)
    assert travel.direction == "claim"
    assert has_element?(view, "#payroll-mapping-#{travel.id}", "Claim category")

    # A refused mapping shows its error on the form.
    view
    |> form("#payroll-mapping-form",
      mapping: %{
        kind: "component",
        code: "fund",
        direction: "deduction",
        expense_account_id: accounts.salaries.id,
        liability_account_id: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#payroll-mapping-liability-account-error-0", "is needed")
    assert {:ok, [_travel, _basic]} = Payroll.list_mappings(operator, 73)

    # Changing one keeps its key and logs the reason.
    view |> element("#payroll-mapping-edit-#{basic.id}") |> render_click()

    view
    |> form("#payroll-mapping-form",
      mapping: %{expense_account_id: accounts.old_expense.id, reason: "capitalised"}
    )
    |> render_submit()

    assert {:ok, mappings} = Payroll.list_mappings(operator, 73)
    assert %{expense_account_id: expense} = Enum.find(mappings, &(&1.id == basic.id))
    assert expense == accounts.old_expense.id
    assert has_element?(view, "#payroll-mapping-changes-table", "capitalised")
  end

  test "refuses a save once the manage grant is revoked after mount", %{
    conn: conn,
    accounts: accounts,
    scope: scope,
    operator: operator
  } do
    grant_capabilities!([@view, @manage, @ledger_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll/setup")
    revoke_capability!(scope, @manage)

    view
    |> form("#payroll-settings-form",
      settings: %{
        net_pay_account_id: accounts.net_pay.id,
        claims_payable_account_id: accounts.claims_payable.id
      }
    )
    |> render_submit()

    assert {:error, :payroll_not_configured} = Payroll.get_settings(operator, 73)
    refute has_element?(view, "#payroll-settings-form")
  end
end
