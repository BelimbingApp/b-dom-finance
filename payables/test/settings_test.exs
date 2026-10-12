defmodule Bilimbi.Finance.Payables.SettingsTest do
  use Bilimbi.Finance.Payables.PayablesCase

  alias Ecto.Adapters.SQL

  describe "settings" do
    test "keep one payable account per company, a liability", context do
      %{operator: operator, accounts: accounts} = context

      assert {:ok, %{company_id: 73, payable_account_id: payable_id}} =
               Payables.get_settings(operator, 73)

      assert payable_id == accounts.payable.id

      assert {:ok, %{payable_account_id: other_id}} =
               Payables.put_settings(operator, 73, %{
                 payable_account_id: accounts.other_payable.id
               })

      assert other_id == accounts.other_payable.id

      assert {:error, changeset} =
               Payables.put_settings(operator, 73, %{payable_account_id: accounts.bank.id})

      assert %{payable_account_id: ["must be an account of type liability"]} =
               errors_on(changeset)

      {:ok, _} = Ledger.update_account(operator, 73, accounts.payable.id, %{active: false})

      assert {:error, changeset} =
               Payables.put_settings(operator, 73, %{payable_account_id: accounts.payable.id})

      assert %{payable_account_id: ["is inactive"]} = errors_on(changeset)

      assert {:error, changeset} = Payables.put_settings(operator, 73, %{payable_account_id: nil})
      assert %{payable_account_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "need the settings grant to change", context do
      viewer =
        TestFixtures.sign_in!(context.first_scope, 73, 93, [
          "finance.payables.view",
          "finance.ledger.view"
        ])

      assert {:ok, _} = Payables.get_settings(viewer, 73)

      assert {:error, :unauthorized} =
               Payables.put_settings(viewer, 73, %{
                 payable_account_id: context.accounts.payable.id
               })

      assert {:error, :unauthorized} =
               Payables.create_tax_code(viewer, 73, %{code: "X", name: "X", rate: "1"})
    end
  end

  describe "tax codes" do
    test "are listed by code and refused when malformed", context do
      %{operator: operator, accounts: accounts} = context
      valid = %{code: "A0", name: "Zero rated", rate: "0", account_id: accounts.tax.id}

      assert {:ok, %{code: "A0", active: true}} = Payables.create_tax_code(operator, 73, valid)
      assert {:ok, [%{code: "A0"}, %{code: "T1"}]} = Payables.list_tax_codes(operator, 73)

      for {attributes, field, message} <- [
            {%{valid | code: "T1"}, :code, "has already been taken"},
            {%{valid | code: "N", rate: "-1"}, :rate, "must be greater than or equal to 0"},
            {%{valid | code: "N", rate: "1.00001"}, :rate, "has more than 4 decimal places"},
            {%{valid | code: "N", rate: "1000"}, :rate, "must be less than 1000"},
            {%{valid | code: "N", account_id: 999_999}, :account_id,
             "is not an account of this company"},
            {%{valid | code: " "}, :code, "can't be blank"}
          ] do
        assert {:error, changeset} = Payables.create_tax_code(operator, 73, attributes)
        assert %{^field => [^message]} = errors_on(changeset)
      end
    end

    test "change without touching documents that copied them", context do
      %{operator: operator, accounts: accounts, tax_code: tax_code} = context

      posted =
        post_bill!(
          context,
          bill("P-1", "INV-1", [line(accounts.expense, "100", %{tax_code_id: tax_code.id})])
        )

      assert {:ok, %{code: "T1", rate: rate, active: false}} =
               Payables.update_tax_code(operator, 73, tax_code.id, %{
                 code: "T9",
                 rate: "10",
                 active: false
               })

      assert decimal?(rate, 10)

      assert {:ok, %{tax_lines: [%{tax_code: "T1", rate: kept, tax_amount: tax}]}} =
               Payables.get_document(operator, 73, posted.id)

      assert decimal?(kept, 8) and decimal?(tax, 8)
      assert {:error, :tax_code_not_found} = Payables.update_tax_code(operator, 73, -1, %{})
    end

    test "keep their code and are never deleted", %{tax_code: tax_code} do
      for {sql, message} <- [
            {"UPDATE finance_payables_tax_codes SET code = 'X' WHERE id = $1",
             ~r/in their company and code/},
            {"DELETE FROM finance_payables_tax_codes WHERE id = $1", ~r/finance payables keeps/}
          ] do
        assert_raise Postgrex.Error, message, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, [tax_code.id]) end)
        end
      end
    end
  end
end
