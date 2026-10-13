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

    test "keep who changed the payable account, why, and from what", context do
      %{first_scope: system, operator: operator, accounts: accounts} = context

      TestFixtures.sign_in!(system, 73, 95, [
        "finance.payables.settings.manage",
        "finance.ledger.view"
      ])

      impersonated =
        Bilimbi.Base.Tenancy.Authentication.sign_in(system, 95, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      payable_id = accounts.payable.id
      other_id = accounts.other_payable.id

      assert {:ok,
              [
                %{
                  old_payable_account_id: nil,
                  new_payable_account_id: ^payable_id,
                  reason: nil,
                  changed_by_user_id: 91,
                  changed_by_impersonator_id: nil,
                  changed_at: %DateTime{}
                }
              ]} = Payables.list_settings_changes(operator, 73)

      assert {:ok, _} =
               Payables.put_settings(impersonated, 73, %{
                 payable_account_id: other_id,
                 reason: " Split the supplier ledger "
               })

      assert {:ok, _} = Payables.put_settings(operator, 73, %{payable_account_id: other_id})

      assert {:error, _} = Payables.put_settings(operator, 73, %{payable_account_id: nil})

      assert {:error, changeset} =
               Payables.put_settings(operator, 73, %{
                 payable_account_id: payable_id,
                 reason: String.duplicate("x", 501)
               })

      assert %{reason: [_]} = errors_on(changeset)
      assert {:ok, %{payable_account_id: ^other_id}} = Payables.get_settings(operator, 73)

      assert {:ok, [_, change]} = Payables.list_settings_changes(operator, 73)

      assert %{
               old_payable_account_id: ^payable_id,
               new_payable_account_id: ^other_id,
               reason: "Split the supplier ledger",
               changed_by_user_id: 95,
               changed_by_impersonator_id: 91
             } = change
    end

    test "keep the match tolerances, each a kind with a value, and their history", context do
      %{operator: operator, accounts: accounts} = context
      payable_id = accounts.payable.id

      assert {:ok, %{quantity_tolerance_kind: nil, quantity_tolerance: nil, price_tolerance: nil}} =
               Payables.get_settings(operator, 73)

      assert {:ok, settings} =
               Payables.put_settings(operator, 73, %{
                 payable_account_id: payable_id,
                 quantity_tolerance_kind: "percent",
                 quantity_tolerance: "2.5",
                 price_tolerance_kind: "amount",
                 price_tolerance: "0.0100",
                 reason: "Agreed with audit"
               })

      assert %{quantity_tolerance_kind: "percent", price_tolerance_kind: "amount"} = settings
      assert decimal?(settings.quantity_tolerance, "2.5")
      assert decimal?(settings.price_tolerance, "0.01")

      for {bad, field, message} <- [
            {%{quantity_tolerance_kind: "ratio", quantity_tolerance: "1"},
             :quantity_tolerance_kind, "is invalid"},
            {%{quantity_tolerance_kind: "amount", quantity_tolerance: "-1"}, :quantity_tolerance,
             "must be greater than or equal to 0"},
            {%{price_tolerance_kind: "amount", price_tolerance: "0.00001"}, :price_tolerance,
             "has more than 4 decimal places"},
            {%{price_tolerance_kind: nil, price_tolerance: "1"}, :price_tolerance_kind,
             "is needed with a tolerance"},
            {%{price_tolerance_kind: "percent", price_tolerance: nil}, :price_tolerance,
             "is needed with a tolerance kind"}
          ] do
        assert {:error, changeset} =
                 Payables.put_settings(
                   operator,
                   73,
                   Map.put(bad, :payable_account_id, payable_id)
                 )

        assert %{^field => [^message]} = errors_on(changeset)
      end

      assert {:ok, _} =
               Payables.put_settings(operator, 73, %{
                 payable_account_id: payable_id,
                 price_tolerance_kind: nil,
                 price_tolerance: nil
               })

      assert {:ok, [_first, change, cleared]} = Payables.list_settings_changes(operator, 73)

      assert %{
               old_quantity_tolerance_kind: nil,
               new_quantity_tolerance_kind: "percent",
               old_price_tolerance: nil,
               new_price_tolerance_kind: "amount",
               reason: "Agreed with audit"
             } = change

      assert decimal?(change.new_quantity_tolerance, "2.5")

      assert %{
               old_price_tolerance_kind: "amount",
               new_price_tolerance_kind: nil,
               new_price_tolerance: nil,
               new_quantity_tolerance_kind: "percent"
             } = cleared

      assert decimal?(cleared.old_price_tolerance, "0.01")
    end

    test "history needs the view grant and a visible company", context do
      editor =
        TestFixtures.sign_in!(context.first_scope, 73, 93, ["finance.payables.settings.manage"])

      assert {:error, :unauthorized} = Payables.list_settings_changes(editor, 73)
      assert {:error, :unauthorized} = Payables.list_tax_code_changes(editor, 73)
      assert {:error, :company_not_found} = Payables.list_settings_changes(context.operator, 75)
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

    test "keep who added or changed them, why, and from what", context do
      %{operator: operator, accounts: accounts, tax_code: tax_code} = context
      tax_id = tax_code.id
      tax_account_id = accounts.tax.id
      stock_id = accounts.stock.id

      assert {:ok, [added]} = Payables.list_tax_code_changes(operator, 73)

      assert %{
               tax_code_id: ^tax_id,
               old_name: nil,
               old_rate: nil,
               old_account_id: nil,
               old_active: nil,
               new_name: "Tax one",
               new_account_id: ^tax_account_id,
               new_active: true,
               reason: nil,
               changed_by_user_id: 91,
               changed_at: %DateTime{}
             } = added

      assert decimal?(added.new_rate, 8)

      assert {:ok, _} =
               Payables.update_tax_code(operator, 73, tax_code.id, %{
                 rate: "10",
                 account_id: stock_id,
                 active: false,
                 reason: "Rate rise"
               })

      assert {:ok, _} = Payables.update_tax_code(operator, 73, tax_code.id, %{rate: "10"})
      assert {:error, _} = Payables.update_tax_code(operator, 73, tax_code.id, %{rate: "-1"})
      assert {:ok, [^added, change]} = Payables.list_tax_code_changes(operator, 73)

      assert %{
               tax_code_id: ^tax_id,
               old_name: "Tax one",
               new_name: "Tax one",
               old_account_id: ^tax_account_id,
               new_account_id: ^stock_id,
               old_active: true,
               new_active: false,
               reason: "Rate rise",
               changed_by_user_id: 91
             } = change

      assert decimal?(change.old_rate, 8) and decimal?(change.new_rate, 10)
    end

    test "the history is append-only", context do
      for sql <- [
            "UPDATE finance_payables_settings_changes SET reason = 'x'",
            "DELETE FROM finance_payables_settings_changes",
            "TRUNCATE finance_payables_settings_changes",
            "UPDATE finance_payables_tax_code_changes SET reason = 'x'",
            "DELETE FROM finance_payables_tax_code_changes",
            "TRUNCATE finance_payables_tax_code_changes"
          ] do
        assert_raise Postgrex.Error, ~r/finance payables keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, []) end)
        end
      end

      assert {:ok, [_]} = Payables.list_settings_changes(context.operator, 73)
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
