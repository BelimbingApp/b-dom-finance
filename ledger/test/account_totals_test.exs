defmodule Bilimbi.Finance.Ledger.AccountTotalsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures

  @view "finance.ledger.view"
  @manage "finance.ledger.accounts.manage"
  @post "finance.ledger.entries.post"

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, [@view, @manage, @post])
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    accounts =
      for {code, type} <- [{"1000", "asset"}, {"3000", "equity"}, {"4000", "income"}],
          into: %{} do
        {:ok, account} =
          Ledger.create_account(operator, 73, %{code: code, name: code, account_type: type})

        {code, account}
      end

    capital =
      post!(operator, accounts, ~D[2026-09-30], [
        {"1000", :debit, "500"},
        {"3000", :credit, "500"}
      ])

    october =
      post!(operator, accounts, ~D[2026-10-05], [
        {"1000", :debit, "120"},
        {"4000", :credit, "120"}
      ])

    november =
      post!(operator, accounts, ~D[2026-11-02], [{"1000", :debit, "80"}, {"4000", :credit, "80"}])

    Map.merge(context, %{
      operator: operator,
      accounts: accounts,
      entries: %{capital: capital, october: october, november: november}
    })
  end

  describe "account_totals/3" do
    test "sums each account's postings dated inside the window", %{operator: operator} do
      assert {:ok, totals} =
               Ledger.account_totals(operator, 73, from: ~D[2026-10-01], to: ~D[2026-10-31])

      assert %{
               from: ~D[2026-10-01],
               to: ~D[2026-10-31],
               through_entry_number: 3,
               currency_code: "XTS",
               minor_units: 2
             } = totals

      assert [cash, income] = totals.rows
      assert {cash.code, income.code} == {"1000", "4000"}
      assert %{account_type: "asset", name: "1000", active: true} = cash
      assert Decimal.equal?(cash.debits, 120) and Decimal.equal?(cash.credits, 0)
      assert Decimal.equal?(income.credits, 120)
    end

    test "without bounds counts every posting, as the trial balance does", %{operator: operator} do
      assert {:ok, %{rows: rows}} = Ledger.account_totals(operator, 73)
      assert Enum.map(rows, & &1.code) == ["1000", "3000", "4000"]
      assert Decimal.equal?(hd(rows).debits, 700)

      assert {:ok, trial_balance} = Ledger.trial_balance(operator, 73, ~D[2026-12-31])

      assert Enum.map(rows, &{&1.id, &1.debits, &1.credits}) ==
               Enum.map(trial_balance.rows, &{&1.id, &1.debits, &1.credits})
    end

    test "reproduces its figures after a back-dated posting", context do
      %{operator: operator, accounts: accounts} = context
      window = [from: ~D[2026-10-01], to: ~D[2026-10-31]]

      assert {:ok, earlier} = Ledger.account_totals(operator, 73, window)
      post!(operator, accounts, ~D[2026-10-20], [{"1000", :debit, "5"}, {"4000", :credit, "5"}])

      assert {:ok, %{through_entry_number: 4, rows: [cash | _]}} =
               Ledger.account_totals(operator, 73, window)

      assert Decimal.equal?(cash.debits, 125)

      assert {:ok, ^earlier} =
               Ledger.account_totals(operator, 73, window ++ [through_entry_number: 3])
    end

    test "refuses a malformed window or entry number", %{operator: operator} do
      for options <- [
            [from: "2026-10-01"],
            [to: ~N[2026-10-01 00:00:00]],
            [from: ~D[2026-10-02], to: ~D[2026-10-01]],
            [through_entry_number: -1],
            [through_entry_number: "3"]
          ] do
        assert {:error, :invalid_option} = Ledger.account_totals(operator, 73, options)
      end
    end

    test "needs the view grant and an open book", %{first_scope: system} do
      clerk = TestFixtures.sign_in!(system, 73, 92, [@post])
      assert {:error, :unauthorized} = Ledger.account_totals(clerk, 73)

      sibling = TestFixtures.sign_in!(system, 74, 93, [@view])
      assert {:error, :book_not_open} = Ledger.account_totals(sibling, 74)

      assert {:error, :company_not_found} = Ledger.account_totals(sibling, 75)
    end
  end

  describe "list_entries/3 behind a figure" do
    test "keeps the entries with a line on the account", context do
      %{operator: operator, accounts: accounts, entries: entries} = context

      assert {:ok, listed} = Ledger.list_entries(operator, 73, account_id: accounts["4000"].id)
      assert Enum.map(listed, & &1.id) == [entries.october.id, entries.november.id]
      assert Enum.all?(listed, &match?([_, _], &1.lines))

      assert {:ok, [only]} =
               Ledger.list_entries(operator, 73,
                 account_id: accounts["4000"].id,
                 from: ~D[2026-10-01],
                 to: ~D[2026-10-31]
               )

      assert only.id == entries.october.id
    end

    test "stops at an entry number, as the figure did", context do
      %{operator: operator, accounts: accounts, entries: entries} = context

      later =
        post!(operator, accounts, ~D[2026-10-20], [{"1000", :debit, "5"}, {"4000", :credit, "5"}])

      income = accounts["4000"].id

      assert {:ok, now} = Ledger.list_entries(operator, 73, account_id: income)
      assert later.id in Enum.map(now, & &1.id)

      assert {:ok, pinned} =
               Ledger.list_entries(operator, 73, account_id: income, through_entry_number: 3)

      assert Enum.map(pinned, & &1.id) == [entries.october.id, entries.november.id]
    end

    test "an account of another company lists nothing", %{operator: operator} do
      assert {:ok, []} = Ledger.list_entries(operator, 73, account_id: 9_999_999)
    end

    test "refuses a malformed account or entry number", %{operator: operator} do
      for options <- [
            [account_id: "1"],
            [account_id: 0],
            [account_id: 9_223_372_036_854_775_808],
            [through_entry_number: -1]
          ] do
        assert {:error, :invalid_option} = Ledger.list_entries(operator, 73, options)
      end
    end
  end

  defp post!(operator, accounts, date, lines) do
    {:ok, entry} =
      Ledger.post_entry(operator, 73, %{
        entry_date: date,
        description: "Entry on #{date}",
        lines:
          for {code, side, amount} <- lines do
            %{:account_id => Map.fetch!(accounts, code).id, side => amount}
          end
      })

    entry
  end
end
