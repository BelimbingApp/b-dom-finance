defmodule Bilimbi.Finance.Payroll.MappingsTest do
  use Bilimbi.Finance.Payroll.PayrollCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  describe "put_mapping/3" do
    test "maps each direction to the accounts it posts to", context do
      context = configure!(context)

      assert {:ok, mappings} = Payroll.list_mappings(context.operator, 73)
      assert length(mappings) == 5

      assert [%{kind: "claim_category", code: "travel", direction: "claim"} = travel | rest] =
               mappings

      assert travel.expense_account_id == context.accounts.travel.id
      assert travel.liability_account_id == nil

      assert %{code: "fund", direction: "employer"} = employer = Enum.at(rest, 2)
      assert employer.expense_account_id == context.accounts.fund_expense.id
      assert employer.liability_account_id == context.accounts.fund_payable.id
    end

    test "refuses the wrong accounts for a direction, and a wrong key", context do
      assert {:error, changeset} =
               Payroll.put_mapping(context.operator, 73, %{
                 kind: "component",
                 code: "basic",
                 direction: "earning",
                 liability_account_id: context.accounts.net_pay.id
               })

      assert %{
               expense_account_id: ["is needed for a earning"],
               liability_account_id: ["is not used by a earning"]
             } = errors_on(changeset)

      assert {:error, changeset} =
               Payroll.put_mapping(context.operator, 73, %{
                 kind: "component",
                 code: "basic",
                 direction: "earning",
                 expense_account_id: context.accounts.net_pay.id
               })

      assert %{expense_account_id: ["must be an account of type asset or expense"]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Payroll.put_mapping(context.operator, 73, %{
                 kind: "claim_category",
                 code: "travel",
                 direction: "earning",
                 expense_account_id: context.accounts.travel.id
               })

      assert %{direction: ["is invalid"]} = errors_on(changeset)

      assert {:error, changeset} =
               Payroll.put_mapping(context.operator, 73, %{
                 kind: "other",
                 code: "",
                 direction: "earning",
                 expense_account_id: context.accounts.travel.id
               })

      assert %{kind: ["is invalid"], code: [_blank]} = errors_on(changeset)
      assert {:ok, []} = Payroll.list_mappings(context.operator, 73)
    end

    test "changes an existing mapping's accounts, keeping its key, and records each change",
         context do
      context = configure!(context)
      basic = Enum.find(context.mappings, &(&1.code == "basic"))

      assert {:ok, changed} =
               Payroll.put_mapping(context.operator, 73, %{
                 kind: "component",
                 code: "basic",
                 direction: "earning",
                 expense_account_id: context.accounts.old_expense.id,
                 reason: "salaries are capitalised this year"
               })

      assert changed.id == basic.id
      assert changed.expense_account_id == context.accounts.old_expense.id

      # The same accounts again record nothing.
      assert {:ok, ^changed} =
               Payroll.put_mapping(context.operator, 73, %{
                 kind: "component",
                 code: "basic",
                 direction: "earning",
                 expense_account_id: context.accounts.old_expense.id
               })

      assert {:ok, changes} = Payroll.list_mapping_changes(context.operator, 73)
      assert length(changes) == 6
      last = List.last(changes)
      assert last.mapping_id == basic.id
      assert last.old_expense_account_id == context.accounts.salaries.id
      assert last.new_expense_account_id == context.accounts.old_expense.id
      assert last.reason == "salaries are capitalised this year"
      assert last.changed_by_user_id == 91
      assert %DateTime{} = last.changed_at
    end

    test "authorizes the capability for the actor now", context do
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 92, ["finance.payroll.view"])

      assert {:error, :unauthorized} =
               Payroll.put_mapping(viewer, 73, %{
                 kind: "component",
                 code: "x",
                 direction: "earning"
               })

      assert {:ok, []} = Payroll.list_mappings(viewer, 73)
      assert {:error, :unauthorized} = Payroll.list_mappings(context.first_scope, 73)
    end
  end

  describe "the database" do
    test "refuses a second mapping of one key, a change of key, and a delete", context do
      context = configure!(context)
      basic = Enum.find(context.mappings, &(&1.code == "basic"))

      assert_raise Postgrex.Error, ~r/finance_payroll_mappings_company_key_unique/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_payroll_mappings (tenant_id, company_id, kind, code, direction, expense_account_id, inserted_at, updated_at) VALUES (41, 73, 'component', 'basic', 'earning', $1, now(), now())",
          [context.accounts.salaries.id]
        )
      end

      assert_raise Postgrex.Error, ~r/in their company and key/, fn ->
        SQL.query!(Repo, "UPDATE finance_payroll_mappings SET code = 'other' WHERE id = $1", [
          basic.id
        ])
      end

      assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_payroll_mappings WHERE id = $1", [basic.id])
      end

      assert_raise Postgrex.Error, ~r/finance_payroll_mappings_accounts/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_payroll_mappings (tenant_id, company_id, kind, code, direction, inserted_at, updated_at) VALUES (41, 73, 'component', 'bonus', 'earning', now(), now())",
          []
        )
      end

      assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
        SQL.query!(Repo, "UPDATE finance_payroll_mapping_changes SET reason = 'x'", [])
      end
    end
  end
end
