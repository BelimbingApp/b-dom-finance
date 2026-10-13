defmodule Bilimbi.Finance.Ledger.TrialBalanceTest do
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
    TestFixtures.open_fiscal_years!(context.first_scope, 73)

    accounts =
      for {code, type} <- [
            {"1000", "asset"},
            {"2000", "liability"},
            {"3000", "equity"},
            {"4000", "income"},
            {"5000", "expense"}
          ],
          into: %{} do
        {:ok, account} =
          Ledger.create_account(operator, 73, %{code: code, name: code, account_type: type})

        {code, account}
      end

    post!(operator, accounts, ~D[2026-10-01], [
      {"1000", :debit, "1000"},
      {"3000", :credit, "1000"}
    ])

    post!(operator, accounts, ~D[2026-10-02], [
      {"5000", :debit, "120.25"},
      {"2000", :credit, "120.25"}
    ])

    sale =
      post!(operator, accounts, ~D[2026-10-03], [
        {"1000", :debit, "300"},
        {"4000", :credit, "300"}
      ])

    Map.merge(context, %{operator: operator, accounts: accounts, sale: sale})
  end

  test "balances every account with a posting up to the date", %{operator: operator} do
    assert {:ok, balance} = Ledger.trial_balance(operator, 73, ~D[2026-10-02])

    assert %{as_of: ~D[2026-10-02], currency_code: "XTS", minor_units: 2} = balance
    assert Enum.map(balance.rows, & &1.code) == ["1000", "2000", "3000", "5000"]

    assert_balances(balance, %{
      "1000" => {"1000", 0},
      "2000" => {0, "120.25"},
      "3000" => {0, "1000"},
      "5000" => {"120.25", 0}
    })

    assert Decimal.equal?(balance.total_debit, "1120.25")
    assert Decimal.equal?(balance.total_credit, "1120.25")
  end

  test "includes later postings and keeps the columns equal", %{operator: operator} do
    assert {:ok, balance} = Ledger.trial_balance(operator, 73, ~D[2026-12-31])

    assert Enum.map(balance.rows, & &1.code) == ["1000", "2000", "3000", "4000", "5000"]
    assert_balances(balance, %{"1000" => {"1300", 0}, "4000" => {0, "300"}})
    assert Decimal.equal?(balance.total_debit, balance.total_credit)
    assert Decimal.equal?(balance.total_debit, "1420.25")
  end

  test "a reversal nets its entry out from its own date", %{operator: operator, sale: sale} do
    assert {:ok, _} =
             Ledger.reverse_entry(operator, 73, sale.id, %{
               entry_date: ~D[2026-10-04],
               description: "Reversal"
             })

    assert {:ok, before} = Ledger.trial_balance(operator, 73, ~D[2026-10-03])
    assert_balances(before, %{"4000" => {0, "300"}})

    assert {:ok, after_reversal} = Ledger.trial_balance(operator, 73, ~D[2026-10-04])
    assert_balances(after_reversal, %{"1000" => {"1000", 0}, "4000" => {0, 0}})

    income = Enum.find(after_reversal.rows, &(&1.code == "4000"))
    assert Decimal.equal?(income.debits, 300) and Decimal.equal?(income.credits, 300)
    assert Decimal.equal?(after_reversal.total_debit, "1120.25")
  end

  test "reproduces an earlier report after a back-dated posting", context do
    %{operator: operator, accounts: accounts} = context

    assert {:ok, %{through_entry_number: 3} = earlier} =
             Ledger.trial_balance(operator, 73, ~D[2026-10-02])

    post!(operator, accounts, ~D[2026-10-01], [{"5000", :debit, "10"}, {"2000", :credit, "10"}])

    assert {:ok, %{through_entry_number: 4} = now} =
             Ledger.trial_balance(operator, 73, ~D[2026-10-02])

    assert Decimal.equal?(now.total_debit, "1130.25")

    assert {:ok, ^earlier} =
             Ledger.trial_balance(operator, 73, ~D[2026-10-02], through_entry_number: 3)

    assert {:error, :invalid_option} =
             Ledger.trial_balance(operator, 73, ~D[2026-10-02], through_entry_number: "3")

    for number <- [-1, 9_223_372_036_854_775_808] do
      assert {:error, :invalid_option} =
               Ledger.trial_balance(operator, 73, ~D[2026-10-02], through_entry_number: number)
    end
  end

  test "is empty before the first posting", %{operator: operator} do
    assert {:ok, %{rows: [], total_debit: debit, total_credit: credit}} =
             Ledger.trial_balance(operator, 73, ~D[2026-09-30])

    assert Decimal.equal?(debit, 0) and Decimal.equal?(credit, 0)
  end

  test "needs the view grant and an open book", %{first_scope: system} do
    clerk = TestFixtures.sign_in!(system, 73, 92, [@post])
    assert {:error, :unauthorized} = Ledger.trial_balance(clerk, 73, ~D[2026-10-03])

    sibling = TestFixtures.sign_in!(system, 74, 93, [@view])
    assert {:error, :book_not_open} = Ledger.trial_balance(sibling, 74, ~D[2026-10-03])
  end

  defp assert_balances(balance, expected) do
    rows = Map.new(balance.rows, &{&1.code, &1})

    for {code, {debit, credit}} <- expected do
      row = Map.fetch!(rows, code)
      assert Decimal.equal?(row.debit_balance, debit), "#{code} debit #{row.debit_balance}"
      assert Decimal.equal?(row.credit_balance, credit), "#{code} credit #{row.credit_balance}"
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
