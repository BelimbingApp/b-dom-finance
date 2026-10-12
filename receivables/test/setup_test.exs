defmodule Bilimbi.Finance.Receivables.SetupTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Receivables.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_receivables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  describe "setup" do
    test "names the receivable and default income accounts", %{operator: operator} = context do
      %{receivable: receivable, income: income, other_income: other} = context.accounts
      assert {:error, :not_configured} = Receivables.get_setup(operator, 73)

      attributes = %{receivable_account_id: receivable.id, income_account_id: income.id}
      assert {:ok, setup} = Receivables.configure(operator, 73, attributes)
      assert {:ok, ^setup} = Receivables.get_setup(operator, 73)

      assert {:ok, %{income_account_id: other_id}} =
               Receivables.configure(operator, 73, %{income_account_id: other.id})

      assert other_id == other.id
    end

    test "keeps a history of every account set or changed", %{operator: operator} = context do
      %{receivable: receivable, income: income, other_income: other} = context.accounts
      assert {:ok, []} = Receivables.list_setup_changes(operator, 73)

      attributes = %{receivable_account_id: receivable.id, income_account_id: income.id}
      assert {:ok, _} = Receivables.configure(operator, 73, attributes)
      assert {:ok, _} = Receivables.configure(operator, 73, attributes)
      assert {:ok, _} = Receivables.configure(operator, 73, %{income_account_id: other.id})

      assert {:ok, [first, second, third] = changes} =
               Receivables.list_setup_changes(operator, 73)

      assert [
               {"receivable_account_id", nil, receivable.id},
               {"income_account_id", nil, income.id},
               {"income_account_id", income.id, other.id}
             ] == Enum.map(changes, &{&1.field, &1.old_value, &1.new_value})

      assert %{changed_by_user_id: 91, changed_by_impersonator_id: nil, changed_at: %DateTime{}} =
               third

      assert {:ok, [^third]} = Receivables.list_setup_changes(operator, 73, after: second.id)
      assert {:ok, [^first]} = Receivables.list_setup_changes(operator, 73, limit: 1)
      assert {:error, :invalid_option} = Receivables.list_setup_changes(operator, 73, limit: 0)

      assert {:error, changeset} =
               Receivables.configure(operator, 73, %{receivable_account_id: other.id})

      assert %{receivable_account_id: [_]} = errors_on(changeset)
      assert {:ok, ^changes} = Receivables.list_setup_changes(operator, 73)

      for sql <- [
            "UPDATE finance_receivables_setup_changes SET new_value = 1",
            "DELETE FROM finance_receivables_setup_changes"
          ] do
        assert_raise Postgrex.Error, ~r/finance receivables keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end

    test "refuses accounts of the wrong type, inactive, or of another company", context do
      %{operator: operator, first_scope: system, accounts: accounts} = context

      assert {:error, changeset} =
               Receivables.configure(operator, 73, %{
                 receivable_account_id: accounts.income.id,
                 income_account_id: accounts.cash.id
               })

      assert %{
               receivable_account_id: ["must be a ledger asset account"],
               income_account_id: ["must be a ledger income account"]
             } = errors_on(changeset)

      {:ok, _} = Ledger.update_account(operator, 73, accounts.receivable.id, %{active: false})
      sibling = TestFixtures.sign_in!(system, 74, 93, TestFixtures.ledger_capabilities())
      {:ok, _} = Ledger.open_book(sibling, 74, %{currency_code: "XTS", minor_units: 2})

      {:ok, foreign} =
        Ledger.create_account(sibling, 74, %{code: "4000", name: "Sales", account_type: "income"})

      assert {:error, changeset} =
               Receivables.configure(operator, 73, %{
                 receivable_account_id: accounts.receivable.id,
                 income_account_id: foreign.id
               })

      assert %{
               receivable_account_id: ["is an inactive ledger account"],
               income_account_id: ["is not a ledger account of this company"]
             } = errors_on(changeset)
    end
  end

  describe "series" do
    test "are unique by code and prefix and keep their identity", %{operator: operator} do
      attributes = %{
        code: "INV",
        name: "Invoices",
        kind: "invoice",
        prefix: "A-",
        number_width: 4
      }

      assert {:ok, series} = Receivables.create_series(operator, 73, attributes)
      assert %{prefix: "A-", number_width: 4, active: true} = series

      assert {:error, changeset} = Receivables.create_series(operator, 73, attributes)
      assert %{code: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Receivables.create_series(operator, 73, %{attributes | code: "OTHER"})

      assert %{prefix: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, %{prefix: ""}} =
               Receivables.create_series(operator, 73, %{
                 attributes
                 | code: "BARE",
                   prefix: "",
                   kind: "payment"
               })

      assert {:ok, %{name: "Renamed", active: false, prefix: "A-", kind: "invoice"}} =
               Receivables.update_series(operator, 73, series.id, %{
                 name: "Renamed",
                 active: false,
                 prefix: "B-",
                 kind: "payment"
               })

      assert {:error, :series_not_found} =
               Receivables.update_series(operator, 73, -1, %{name: "x"})

      assert {:error, changeset} = Receivables.update_series(operator, 73, series.id, %{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)

      assert_raise Postgrex.Error, ~r/finance receivables keeps prefix/, fn ->
        SQL.query!(Repo, "UPDATE finance_receivables_series SET prefix = 'Z-'", [])
      end
    end

    test "refuse an unknown kind and an out-of-range width", %{operator: operator} do
      assert {:error, changeset} =
               Receivables.create_series(operator, 73, %{
                 code: "X",
                 name: "X",
                 kind: "receipt",
                 number_width: 13
               })

      assert %{kind: ["is invalid"], number_width: [_]} = errors_on(changeset)
      assert Receivables.series_kinds() == ["invoice", "credit_note", "payment"]
    end
  end

  describe "tax codes" do
    test "carry a fixed code and rate and post to a liability account", context do
      %{operator: operator, accounts: accounts} = context

      assert {:ok, tax_code} =
               Receivables.create_tax_code(operator, 73, %{
                 code: "S",
                 name: "Standard",
                 rate: "8.25",
                 account_id: accounts.tax.id
               })

      assert Decimal.equal?(tax_code.rate, "8.25")

      assert {:ok, %{name: "Renamed", active: false} = updated} =
               Receivables.update_tax_code(operator, 73, tax_code.id, %{
                 name: "Renamed",
                 active: false,
                 rate: "9"
               })

      assert Decimal.equal?(updated.rate, "8.25")

      assert {:error, changeset} =
               Receivables.update_tax_code(operator, 73, tax_code.id, %{
                 account_id: accounts.income.id
               })

      assert %{account_id: ["must be a ledger liability account"]} = errors_on(changeset)

      assert {:error, changeset} =
               Receivables.update_tax_code(operator, 73, tax_code.id, %{name: ""})

      assert %{name: ["can't be blank"]} = errors_on(changeset)

      for rate <- ["-1", "1000", "1.00001"] do
        assert {:error, changeset} =
                 Receivables.create_tax_code(operator, 73, %{
                   code: "R#{rate}",
                   name: "Rate",
                   rate: rate,
                   account_id: accounts.tax.id
                 })

        assert %{rate: [_]} = errors_on(changeset)
      end
    end
  end

  describe "customers" do
    test "keep their code; everything else changes", %{operator: operator} do
      assert {:ok, customer} =
               Receivables.create_customer(operator, 73, %{
                 code: " C1 ",
                 name: "A Customer",
                 country_iso: "xx",
                 payment_terms_days: 14
               })

      assert %{code: "C1", country_iso: "XX", payment_terms_days: 14, active: true} = customer

      assert {:ok, %{name: "Renamed", code: "C1", active: false}} =
               Receivables.update_customer(operator, 73, customer.id, %{
                 name: "Renamed",
                 code: "C2",
                 active: false
               })

      assert {:ok, [%{code: "C1"}]} = Receivables.list_customers(operator, 73)
      assert {:error, :customer_not_found} = Receivables.get_customer(operator, 73, -1)

      assert {:error, changeset} =
               Receivables.create_customer(operator, 73, %{code: "C1", name: "Duplicate"})

      assert %{code: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} =
               Receivables.create_customer(operator, 73, %{
                 code: "C3",
                 name: "Malformed",
                 country_iso: "XXX",
                 payment_terms_days: -1
               })

      assert %{country_iso: [_], payment_terms_days: [_]} = errors_on(changeset)

      assert_raise Postgrex.Error, ~r/finance receivables keeps/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_receivables_customers", [])
      end
    end

    test "clear an optional field, but not a required one", %{operator: operator} do
      assert {:ok, customer} =
               Receivables.create_customer(operator, 73, %{
                 code: "C1",
                 name: "A Customer",
                 email: "a@example.test",
                 country_iso: "XX"
               })

      assert {:ok, %{email: nil, country_iso: nil, name: "A Customer"}} =
               Receivables.update_customer(operator, 73, customer.id, %{
                 email: "",
                 country_iso: nil
               })

      assert {:error, changeset} =
               Receivables.update_customer(operator, 73, customer.id, %{name: ""})

      assert %{name: ["can't be blank"]} = errors_on(changeset)
      assert {:ok, %{name: "A Customer"}} = Receivables.get_customer(operator, 73, customer.id)
    end
  end

  describe "authorization" do
    test "every call checks the actor's grant and company reach", context do
      %{first_scope: system, second_scope: other_tenant, operator: operator} = context
      viewer = TestFixtures.sign_in!(system, 73, 94, [Receivables.view_capability()])

      assert {:ok, []} = Receivables.list_customers(viewer, 73)

      assert {:error, :unauthorized} =
               Receivables.create_customer(viewer, 73, %{code: "C", name: "C"})

      assert {:error, :unauthorized} = Receivables.list_customers(system, 73)
      assert {:error, :unauthorized} = Receivables.list_customers(operator, 74)
      assert {:error, :company_not_found} = Receivables.list_customers(operator, 75)

      outsider = TestFixtures.sign_in!(other_tenant, 75, 95, [Receivables.view_capability()])
      assert {:error, :company_not_found} = Receivables.list_customers(outsider, 73)
    end

    test "receivables' reads of the chart need the ledger grant too", context do
      setup_only =
        TestFixtures.sign_in!(context.first_scope, 73, 96, [Receivables.manage_setup_capability()])

      assert {:error, :unauthorized} =
               Receivables.configure(setup_only, 73, %{
                 receivable_account_id: context.accounts.receivable.id,
                 income_account_id: context.accounts.income.id
               })
    end
  end
end
