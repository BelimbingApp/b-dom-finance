defmodule Bilimbi.Finance.Ledger.AccountsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "finance.ledger.view"
  @manage "finance.ledger.accounts.manage"
  @post "finance.ledger.entries.post"

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, [@view, @manage])
    Map.put(context, :operator, operator)
  end

  describe "the book" do
    test "opens once with an explicit currency and its minor units", %{operator: operator} do
      assert {:error, :book_not_open} = Ledger.get_book(operator, 73)

      assert {:ok, %{company_id: 73, currency_code: "XTS", minor_units: 2}} =
               Ledger.open_book(operator, 73, %{currency_code: " xts ", minor_units: 2})

      assert {:ok, %{currency_code: "XTS"}} = Ledger.get_book(operator, 73)

      assert {:error, :book_already_open} =
               Ledger.open_book(operator, 73, %{currency_code: "XXX", minor_units: 0})
    end

    test "refuses a malformed currency or minor units", %{operator: operator} do
      assert {:error, changeset} =
               Ledger.open_book(operator, 73, %{currency_code: "X1", minor_units: 5})

      assert %{currency_code: [_], minor_units: [_]} = errors_on(changeset)
      assert {:error, :book_not_open} = Ledger.get_book(operator, 73)
    end

    test "the database keeps a book as opened", %{operator: operator} do
      {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

      for sql <- [
            "UPDATE finance_ledger_books SET currency_code = 'XXX'",
            "DELETE FROM finance_ledger_books"
          ] do
        assert_raise Postgrex.Error, ~r/finance ledger keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, []) end)
        end
      end
    end
  end

  describe "authorization" do
    test "refuses a scope without a person, a grant, or reach", context do
      %{first_scope: system, operator: operator} = context
      viewer = TestFixtures.sign_in!(system, 73, 92, [@view])
      sibling = TestFixtures.sign_in!(system, 74, 93, [@view, @manage])

      assert {:error, :unauthorized} = Ledger.list_accounts(system, 73)
      assert {:error, :unauthorized} = Ledger.create_account(viewer, 73, cash())
      assert {:error, :unauthorized} = Ledger.list_accounts(sibling, 73)
      assert {:error, :unauthorized} = Ledger.create_account(sibling, 73, cash())
      assert {:error, :unauthorized} = Ledger.create_account(operator, 74, cash())
      assert {:error, :company_not_found} = Ledger.list_accounts(operator, 75)
      assert {:error, :company_not_found} = Ledger.create_account(operator, 75, cash())

      assert {:ok, []} = Ledger.list_accounts(viewer, 73)
    end

    test "a revoked grant refuses the next call", %{first_scope: system, operator: operator} do
      assert {:ok, _account} = Ledger.create_account(operator, 73, cash())
      :ok = TestFixtures.revoke!(system, 73, 91, @manage)

      assert {:error, :unauthorized} =
               Ledger.create_account(operator, 73, %{cash() | code: "1001"})

      assert {:ok, [_one]} = Ledger.list_accounts(operator, 73)
    end

    test "an archived company is read-only", %{operator: operator} do
      SQL.query!(Repo, "UPDATE companies SET status = 'archived' WHERE id = 73", [])

      assert {:error, :company_archived} = Ledger.create_account(operator, 73, cash())

      assert {:error, :company_archived} =
               Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

      assert {:ok, []} = Ledger.list_accounts(operator, 73)
    end

    test "tenant-wide reach opens a sibling company", %{first_scope: system} do
      group =
        TestFixtures.sign_in!(system, 73, 94, [
          @view,
          @manage,
          "admin.company.tenant-wide.manage"
        ])

      assert {:ok, %{code: "1000"}} = Ledger.create_account(group, 74, cash())
      assert {:ok, []} = Ledger.list_accounts(group, 73)
    end
  end

  describe "the chart of accounts" do
    test "keeps codes unique per company and types to the five kinds", %{operator: operator} do
      assert {:ok, account} = Ledger.create_account(operator, 73, cash())

      assert %{code: "1000", name: "Cash", account_type: "asset", parent_id: nil, active: true} =
               account

      assert {:error, changeset} = Ledger.create_account(operator, 73, cash())
      assert %{code: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Ledger.create_account(operator, 73, %{cash() | code: "9", account_type: "other"})

      assert %{account_type: [_]} = errors_on(changeset)
      assert Ledger.account_types() == ~w(asset liability equity income expense)
    end

    test "groups an account under a parent of its own type and company", context do
      %{first_scope: system, operator: operator} = context
      {:ok, assets} = Ledger.create_account(operator, 73, %{cash() | code: "1", name: "Assets"})
      {:ok, income} = Ledger.create_account(operator, 73, income())

      assert {:ok, %{parent_id: parent_id}} =
               Ledger.create_account(operator, 73, Map.put(cash(), :parent_id, assets.id))

      assert parent_id == assets.id

      assert {:error, changeset} =
               Ledger.create_account(
                 operator,
                 73,
                 %{cash() | code: "1100"} |> Map.put(:parent_id, income.id)
               )

      assert %{parent_id: ["must have the same account type"]} = errors_on(changeset)

      sibling = TestFixtures.sign_in!(system, 74, 93, [@manage])
      {:ok, foreign} = Ledger.create_account(sibling, 74, cash())

      assert {:error, changeset} =
               Ledger.create_account(
                 operator,
                 73,
                 %{cash() | code: "1200"} |> Map.put(:parent_id, foreign.id)
               )

      assert %{parent_id: ["is not an account of this company"]} = errors_on(changeset)
    end

    test "refuses a parent cycle", %{operator: operator} do
      {:ok, top} = Ledger.create_account(operator, 73, %{cash() | code: "1"})

      {:ok, middle} =
        Ledger.create_account(operator, 73, Map.put(%{cash() | code: "10"}, :parent_id, top.id))

      assert {:error, changeset} =
               Ledger.update_account(operator, 73, top.id, %{parent_id: middle.id})

      assert %{parent_id: ["would place the account under itself"]} = errors_on(changeset)

      assert {:error, changeset} =
               Ledger.update_account(operator, 73, top.id, %{parent_id: top.id})

      assert %{parent_id: ["would place the account under itself"]} = errors_on(changeset)
    end

    test "changes name, parent and active flag but never code or type", %{operator: operator} do
      {:ok, account} = Ledger.create_account(operator, 73, cash())

      assert {:ok, %{code: "1000", account_type: "asset", name: "Petty cash", active: false}} =
               Ledger.update_account(operator, 73, account.id, %{
                 name: "Petty cash",
                 active: false,
                 code: "2000",
                 account_type: "liability"
               })

      assert {:error, :account_not_found} =
               Ledger.update_account(operator, 73, account.id + 1000, %{name: "Missing"})

      for sql <- [
            "UPDATE finance_ledger_accounts SET code = 'X' WHERE id = $1",
            "UPDATE finance_ledger_accounts SET account_type = 'equity' WHERE id = $1",
            "DELETE FROM finance_ledger_accounts WHERE id = $1"
          ] do
        assert_raise Postgrex.Error, ~r/ledger account keeps|finance ledger keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, [account.id]) end)
        end
      end
    end

    test "deactivates only at a zero balance", context do
      poster = TestFixtures.sign_in!(context.first_scope, 73, 92, [@view, @manage, @post])
      {:ok, _book} = Ledger.open_book(poster, 73, %{currency_code: "XTS", minor_units: 2})
      {:ok, cash} = Ledger.create_account(poster, 73, cash())
      {:ok, income} = Ledger.create_account(poster, 73, income())

      post = fn lines ->
        Ledger.post_entry(poster, 73, %{
          entry_date: ~D[2026-10-01],
          description: "Entry",
          lines: lines
        })
      end

      {:ok, _} =
        post.([%{account_id: cash.id, debit: "50"}, %{account_id: income.id, credit: "50"}])

      assert {:error, changeset} = Ledger.update_account(poster, 73, cash.id, %{active: false})

      assert %{
               active: [
                 "account 1000 has a balance of 50.00; it can be deactivated once its balance is zero"
               ]
             } = errors_on(changeset)

      assert {:error, changeset} = Ledger.update_account(poster, 73, income.id, %{active: false})
      assert %{active: ["account 4000 has a balance of 50.00; " <> _]} = errors_on(changeset)

      # Other changes are unaffected while the balance stands.
      assert {:ok, %{name: "Renamed", active: true}} =
               Ledger.update_account(poster, 73, cash.id, %{name: "Renamed"})

      {:ok, _} =
        post.([%{account_id: cash.id, credit: "50"}, %{account_id: income.id, debit: "50"}])

      assert {:ok, %{active: false}} =
               Ledger.update_account(poster, 73, cash.id, %{active: false})

      assert {:ok, %{active: false}} =
               Ledger.update_account(poster, 73, income.id, %{active: false})

      assert {:ok, %{active: true}} = Ledger.update_account(poster, 73, cash.id, %{active: true})
    end

    test "lists accounts by code and only the company's own", %{operator: operator} = context do
      sibling = TestFixtures.sign_in!(context.first_scope, 74, 93, [@manage])
      {:ok, _} = Ledger.create_account(sibling, 74, %{cash() | code: "0001"})
      {:ok, _} = Ledger.create_account(operator, 73, income())
      {:ok, _} = Ledger.create_account(operator, 73, cash())

      assert {:ok, [%{code: "1000"}, %{code: "4000"}]} = Ledger.list_accounts(operator, 73)
    end
  end

  defp cash, do: %{code: "1000", name: "Cash", account_type: "asset"}
  defp income, do: %{code: "4000", name: "Sales", account_type: "income"}
end
