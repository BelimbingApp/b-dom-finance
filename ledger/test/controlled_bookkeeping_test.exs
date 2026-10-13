defmodule Bilimbi.Finance.Ledger.ControlledBookkeepingTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "finance.ledger.view"
  @manage "finance.ledger.accounts.manage"
  @post "finance.ledger.entries.post"
  @periods "finance.ledger.periods.manage"
  @controlled "finance.ledger.controlled-bookkeeping.manage"
  @review "finance.ledger.approval-exceptions.review"

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator =
      TestFixtures.sign_in!(context.first_scope, 73, 91, [
        @view,
        @manage,
        @post,
        @periods,
        @controlled,
        @review
      ])

    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    {:ok, cash} = Ledger.create_account(operator, 73, account("1000", "asset"))
    {:ok, income} = Ledger.create_account(operator, 73, account("4000", "income"))

    Map.merge(context, %{operator: operator, cash: cash, income: income})
  end

  describe "the setting" do
    test "a new company's book opens controlled, with no fiscal year yet", %{operator: operator} do
      assert {:ok, %{controlled: true, fiscal_years: 0, change: change}} =
               Ledger.get_controlled_bookkeeping(operator, 73)

      assert %{change_number: 1, controlled: true, reason: nil, changed_by_user_id: 91} = change
    end

    test "a setting turned on before the book opens does not stop the book opening",
         %{first_scope: first} do
      sibling = TestFixtures.sign_in!(first, 74, 91, [@view, @manage, @controlled])

      assert {:ok, %{controlled: true}} =
               Ledger.set_controlled_bookkeeping(sibling, 74, %{controlled: true})

      assert {:ok, %{currency_code: "XTS"}} =
               Ledger.open_book(sibling, 74, %{currency_code: "XTS", minor_units: 2})

      assert {:ok, %{controlled: true}} = Ledger.get_controlled_bookkeeping(sibling, 74)
      assert {:ok, [_only]} = Ledger.list_controlled_bookkeeping_changes(sibling, 74)
    end

    test "turning it off needs a reason and is listed as an override", %{operator: operator} do
      assert {:error, changeset} =
               Ledger.set_controlled_bookkeeping(operator, 73, %{controlled: false})

      assert %{reason: ["is required to turn this off"]} = errors_on(changeset)

      assert {:ok, %{controlled: false}} =
               Ledger.set_controlled_bookkeeping(operator, 73, %{
                 controlled: false,
                 reason: "Migrating from a legacy system"
               })

      assert {:ok, [%{change_number: 1}, %{change_number: 2, controlled: false} = off]} =
               Ledger.list_controlled_bookkeeping_changes(operator, 73)

      assert off.reason == "Migrating from a legacy system"

      assert {:ok, [exception]} = Ledger.list_approval_exceptions(operator, 73)

      assert %{
               source: "finance/ledger",
               action: "controlled_bookkeeping_off",
               subject_type: "bookkeeping",
               override: true,
               same_person: false,
               reason: "Migrating from a legacy system"
             } = exception
    end

    test "turning it on needs no reason, and a call that changes nothing records nothing",
         %{operator: operator} do
      assert {:ok, %{controlled: true}} =
               Ledger.set_controlled_bookkeeping(operator, 73, %{controlled: true})

      assert {:ok, [_only]} = Ledger.list_controlled_bookkeeping_changes(operator, 73)
      assert {:ok, []} = Ledger.list_approval_exceptions(operator, 73)
    end

    test "changing it needs its capability", %{first_scope: first} do
      reader = TestFixtures.sign_in!(first, 73, 92, [@view])

      assert {:error, :unauthorized} =
               Ledger.set_controlled_bookkeeping(reader, 73, %{controlled: false, reason: "x"})
    end
  end

  describe "posting into fiscal periods" do
    test "a controlled company refuses a date no fiscal year covers, until its first year is opened",
         %{operator: operator} = context do
      assert {:error, changeset} = post(context, ~D[2026-10-01])
      assert %{entry_date: ["falls in no fiscal period" <> _]} = errors_on(changeset)

      assert {:ok, %{fiscal_years: 0}} = Ledger.get_controlled_bookkeeping(operator, 73)

      assert {:ok, _year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-01-01]})
      assert {:ok, %{fiscal_years: 1}} = Ledger.get_controlled_bookkeeping(operator, 73)
      assert {:ok, %{entry_number: 1}} = post(context, ~D[2026-10-01])
    end

    test "a controlled company refuses a date after its last year",
         %{operator: operator} = context do
      {:ok, _year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-01-01]})

      assert {:error, changeset} = post(context, ~D[2027-01-01])
      assert %{entry_date: ["falls in no fiscal period" <> _]} = errors_on(changeset)
    end

    test "old transactions post into an open period however late they are recorded",
         %{operator: operator} = context do
      {:ok, _year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2025-01-01]})

      assert {:ok, %{entry_date: ~D[2025-03-14]}} = post(context, ~D[2025-03-14])
    end

    test "an uncontrolled company posts after its last year, as it did before",
         %{
           operator: operator
         } = context do
      {:ok, _year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-01-01]})

      {:ok, _} =
        Ledger.set_controlled_bookkeeping(operator, 73, %{controlled: false, reason: "Legacy"})

      assert {:ok, %{entry_number: 1}} = post(context, ~D[2027-01-01])
    end

    test "a closed period is refused, not reopened", %{operator: operator} = context do
      {:ok, year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-01-01]})
      [january | _] = year.periods
      {:ok, _} = Ledger.close_period(operator, 73, january.id, %{reason: "Month end"})

      assert {:error, changeset} = post(context, ~D[2026-01-20])
      assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)
    end
  end

  defp post(%{operator: operator, cash: cash, income: income}, date) do
    Ledger.post_entry(operator, 73, %{
      entry_date: date,
      description: "Sale",
      lines: [
        %{account_id: cash.id, debit: "10"},
        %{account_id: income.id, credit: "10"}
      ]
    })
  end

  defp account(code, type),
    do: %{code: code, name: code, account_type: type}
end
