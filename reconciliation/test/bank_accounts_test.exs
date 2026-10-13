defmodule Bilimbi.Finance.Reconciliation.BankAccountsTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  describe "creating a bank account" do
    test "maps an active asset account once and fills the mapping's defaults", context do
      %{operator: operator, accounts: accounts, bank_account: bank_account} = context

      assert bank_account.ledger_account_id == accounts.bank.id
      assert bank_account.match_window_days == 5
      assert bank_account.active

      assert bank_account.import_mapping == %{
               "delimiter" => ",",
               "header_rows" => 1,
               "date" => "Date",
               "date_format" => "YYYY-MM-DD",
               "description" => "Description",
               "reference" => "Reference",
               "amount" => "Amount",
               "amount_sign" => "deposits_positive",
               "debit" => nil,
               "credit" => nil,
               "balance" => "Balance",
               "decimal_separator" => "."
             }

      assert {:error, changeset} =
               Reconciliation.create_bank_account(operator, 73, %{
                 name: "Second mapping of the same account",
                 ledger_account_id: accounts.bank.id,
                 import_mapping: TestFixtures.mapping()
               })

      assert %{ledger_account_id: ["already has a bank account"]} = errors_on(changeset)

      assert {:error, changeset} =
               Reconciliation.create_bank_account(operator, 73, %{
                 name: "Operating account",
                 ledger_account_id: accounts.other_bank.id,
                 import_mapping: TestFixtures.mapping()
               })

      assert %{name: ["is already a bank account of this company"]} = errors_on(changeset)
    end

    test "refuses a ledger account of the wrong type, an inactive one, or another company's",
         context do
      %{operator: operator, accounts: accounts} = context

      for {id, message} <- [
            {accounts.income.id, "must be a ledger asset account"},
            {999_999, "is not a ledger account of this company"}
          ] do
        assert {:error, changeset} =
                 Reconciliation.create_bank_account(operator, 73, %{
                   name: "Account #{id}",
                   ledger_account_id: id,
                   import_mapping: TestFixtures.mapping()
                 })

        assert %{ledger_account_id: [^message]} = errors_on(changeset)
      end

      {:ok, _} = Ledger.update_account(operator, 73, accounts.other_bank.id, %{active: false})

      assert {:error, changeset} =
               Reconciliation.create_bank_account(operator, 73, %{
                 name: "Dormant",
                 ledger_account_id: accounts.other_bank.id,
                 charges_account_id: accounts.income.id,
                 import_mapping: TestFixtures.mapping()
               })

      assert %{
               ledger_account_id: ["is an inactive ledger account"],
               charges_account_id: ["must be a ledger expense account"]
             } = errors_on(changeset)
    end

    test "validates the import mapping", context do
      %{operator: operator, accounts: accounts} = context

      for {mapping, message} <- [
            {%{"date" => "Date"}, "description column is required"},
            {%{"date" => "Date", "description" => "D"},
             "needs an amount column, or both a debit and a credit column"},
            {%{"date" => "Date", "description" => "D", "amount" => "A", "debit" => "Dr"},
             "names an amount column and debit or credit columns; use one or the other"},
            {%{"date" => "Date", "description" => "D", "amount" => "A", "date_format" => "D/M/Y"},
             "date_format must be one of"},
            {%{"date" => "Date", "description" => "D", "amount" => "A", "colour" => "blue"},
             "has unknown settings: colour"},
            {%{"date" => "Date", "description" => "D", "amount" => "A", "header_rows" => 0},
             "date must be a column position (1, 2, ...) because the file has no header row"}
          ] do
        assert {:error, changeset} =
                 Reconciliation.create_bank_account(operator, 73, %{
                   name: "Mapped",
                   ledger_account_id: accounts.other_bank.id,
                   import_mapping: mapping
                 })

        assert %{import_mapping: [error]} = errors_on(changeset)
        assert error =~ message
      end

      assert {:ok, positional} =
               Reconciliation.create_bank_account(operator, 73, %{
                 name: "Positional",
                 ledger_account_id: accounts.other_bank.id,
                 import_mapping: %{
                   "header_rows" => 0,
                   "date" => 1,
                   "description" => 2,
                   "debit" => 3,
                   "credit" => 4,
                   "delimiter" => ";"
                 }
               })

      assert positional.import_mapping["debit"] == 3
      assert positional.import_mapping["amount"] == nil
    end

    test "needs the bank-accounts capability for the actor's own company", context do
      %{first_scope: first, second_scope: second, accounts: accounts} = context

      viewer =
        TestFixtures.sign_in!(first, 73, 92, [
          "finance.reconciliation.view",
          "finance.ledger.view"
        ])

      attributes = %{
        name: "Another",
        ledger_account_id: accounts.other_bank.id,
        import_mapping: TestFixtures.mapping()
      }

      assert {:error, :unauthorized} = Reconciliation.create_bank_account(viewer, 73, attributes)
      assert {:ok, [_one]} = Reconciliation.list_bank_accounts(viewer, 73)
      assert {:error, :unauthorized} = Reconciliation.list_bank_accounts(first, 73)
      assert {:error, :company_not_found} = Reconciliation.list_bank_accounts(viewer, 75)

      stranger = TestFixtures.sign_in!(second, 75, 93, reconciliation_capabilities())
      assert {:error, :company_not_found} = Reconciliation.list_bank_accounts(stranger, 73)
    end
  end

  describe "changing a bank account" do
    test "logs every change with its actor and reason and keeps the ledger account", context do
      %{operator: operator, accounts: accounts, bank_account: bank_account} = context

      assert {:ok, changed} =
               Reconciliation.update_bank_account(operator, 73, bank_account.id, %{
                 name: "Main operating account",
                 match_window_days: 10,
                 ledger_account_id: accounts.other_bank.id,
                 reason: "Renamed after the bank merger"
               })

      assert changed.name == "Main operating account"
      assert changed.match_window_days == 10
      assert changed.ledger_account_id == accounts.bank.id

      assert {:ok, changes} =
               Reconciliation.list_bank_account_changes(operator, 73, bank_account.id)

      first = Enum.filter(changes, &is_nil(&1.old_value))

      assert Enum.map(first, & &1.field) |> Enum.sort() ==
               ~w(active charges_account_id import_mapping interest_account_id match_window_days name)

      later = Enum.reject(changes, &is_nil(&1.old_value))

      assert [
               %{
                 field: "match_window_days",
                 old_value: "5",
                 new_value: "10",
                 reason: reason,
                 changed_by_user_id: 91
               },
               %{
                 field: "name",
                 old_value: "Operating account",
                 new_value: "Main operating account"
               }
             ] = Enum.sort_by(later, & &1.field)

      assert reason == "Renamed after the bank merger"
      assert Enum.all?(changes, &match?(%DateTime{}, &1.changed_at))

      assert {:error, changeset} =
               Reconciliation.update_bank_account(operator, 73, bank_account.id, %{
                 interest_account_id: accounts.expense.id
               })

      assert %{interest_account_id: ["must be a ledger income account"]} = errors_on(changeset)

      assert {:error, :bank_account_not_found} =
               Reconciliation.update_bank_account(operator, 73, 999, %{name: "Nobody"})
    end

    test "the database keeps the ledger account and the change log", context do
      %{bank_account: bank_account, accounts: accounts} = context

      assert_raise Postgrex.Error, ~r/keeps its company and ledger account/, fn ->
        SQL.query!(
          Repo,
          "UPDATE finance_reconciliation_bank_accounts SET ledger_account_id = $1 WHERE id = $2",
          [accounts.other_bank.id, bank_account.id]
        )
      end

      for sql <- [
            "DELETE FROM finance_reconciliation_bank_accounts",
            "UPDATE finance_reconciliation_bank_account_changes SET reason = 'x'",
            "DELETE FROM finance_reconciliation_bank_account_changes"
          ] do
        assert_raise Postgrex.Error, ~r/finance reconciliation keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end
  end
end
