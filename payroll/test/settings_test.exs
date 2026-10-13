defmodule Bilimbi.Finance.Payroll.SettingsTest do
  use Bilimbi.Finance.Payroll.PayrollCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  describe "get_settings/2 and put_settings/3" do
    test "are unset until set, then name the two liability accounts", context do
      assert {:error, :payroll_not_configured} = Payroll.get_settings(context.operator, 73)

      assert {:ok, settings} =
               Payroll.put_settings(context.operator, 73, %{
                 net_pay_account_id: context.accounts.net_pay.id,
                 claims_payable_account_id: context.accounts.claims_payable.id,
                 reason: "first setup"
               })

      assert settings.company_id == 73
      assert settings.net_pay_account_id == context.accounts.net_pay.id
      assert {:ok, ^settings} = Payroll.get_settings(context.operator, 73)
    end

    test "refuse an account that is not a liability, inactive, or not the company's", context do
      assert {:error, changeset} =
               Payroll.put_settings(context.operator, 73, %{
                 net_pay_account_id: context.accounts.salaries.id,
                 claims_payable_account_id: context.accounts.claims_payable.id
               })

      assert %{net_pay_account_id: ["must be an account of type liability"]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Payroll.put_settings(context.operator, 73, %{
                 net_pay_account_id: 999_999,
                 claims_payable_account_id: context.accounts.claims_payable.id
               })

      assert %{net_pay_account_id: ["is not an account of this company"]} = errors_on(changeset)

      {:ok, _} =
        Ledger.update_account(context.operator, 73, context.accounts.tax_payable.id, %{
          active: false
        })

      assert {:error, changeset} =
               Payroll.put_settings(context.operator, 73, %{
                 net_pay_account_id: context.accounts.net_pay.id,
                 claims_payable_account_id: context.accounts.tax_payable.id
               })

      assert %{claims_payable_account_id: ["is inactive"]} = errors_on(changeset)
      assert {:error, :payroll_not_configured} = Payroll.get_settings(context.operator, 73)
    end

    test "record every change with its actor, reason, and the values before and after", context do
      configure!(context)

      {:ok, _} =
        Payroll.put_settings(context.operator, 73, %{
          net_pay_account_id: context.accounts.net_pay.id,
          claims_payable_account_id: context.accounts.fund_payable.id,
          reason: "claims move to their own account"
        })

      # A call that changes nothing records nothing.
      {:ok, _} =
        Payroll.put_settings(context.operator, 73, %{
          net_pay_account_id: context.accounts.net_pay.id,
          claims_payable_account_id: context.accounts.fund_payable.id
        })

      assert {:ok, [first, second]} = Payroll.list_settings_changes(context.operator, 73)
      assert first.old_net_pay_account_id == nil
      assert first.new_net_pay_account_id == context.accounts.net_pay.id
      assert first.changed_by_user_id == 91
      assert second.old_claims_payable_account_id == context.accounts.claims_payable.id
      assert second.new_claims_payable_account_id == context.accounts.fund_payable.id
      assert second.reason == "claims move to their own account"
      assert %DateTime{} = second.changed_at
      assert DateTime.compare(first.changed_at, second.changed_at) == :lt
    end

    test "authorize the capability and the company for the actor now", context do
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 92, ["finance.payroll.view"])
      attributes = %{net_pay_account_id: 1, claims_payable_account_id: 2}

      assert {:error, :unauthorized} = Payroll.put_settings(viewer, 73, attributes)
      assert {:error, :unauthorized} = Payroll.put_settings(context.first_scope, 73, attributes)
      assert {:error, :unauthorized} = Payroll.get_settings(context.first_scope, 73)
      assert {:error, :company_not_found} = Payroll.get_settings(context.operator, 75)
      assert {:error, :unauthorized} = Payroll.get_settings(viewer, 74)
      assert {:error, :payroll_not_configured} = Payroll.get_settings(viewer, 73)
    end
  end

  describe "the database" do
    test "keeps the settings in their company and the changes as written", context do
      configure!(context)

      assert_raise Postgrex.Error, ~r/keeps finance_payroll_settings rows in their company/, fn ->
        SQL.query!(Repo, "UPDATE finance_payroll_settings SET company_id = 74", [])
      end

      assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_payroll_settings", [])
      end

      assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
        SQL.query!(Repo, "UPDATE finance_payroll_settings_changes SET reason = 'x'", [])
      end

      assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_payroll_settings_changes", [])
      end
    end
  end
end
