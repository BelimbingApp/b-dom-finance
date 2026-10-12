defmodule Bilimbi.Finance.Reports.AccountActivityTest do
  # The contribution registry snapshot is process-global, so this suite runs
  # alone.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reports
  alias Bilimbi.Finance.Reports.TestFixtures

  setup do
    context = TestFixtures.setup_reports!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    %{operator: operator, accounts: accounts} = context

    entries =
      for {date, lines} <- [
            {~D[2026-10-03], [{"1010", :debit, "300"}, {"4000", :credit, "300"}]},
            {~D[2026-10-09],
             [{"1010", :debit, "80"}, {"1020", :debit, "20"}, {"4000", :credit, "100"}]},
            {~D[2026-11-05], [{"1010", :debit, "70"}, {"4000", :credit, "70"}]}
          ] do
        TestFixtures.post!(operator, accounts, date, lines)
      end

    Map.put(context, :entries, entries)
  end

  test "lists the entries behind a report's figure, and its totals equal the figure", context do
    %{operator: operator, accounts: accounts, entries: [first, second, _november]} = context
    income = accounts["4000"]

    assert {:ok, %{groups: [%{sections: [%{rows: [row]}]} | _]} = report} =
             Reports.profit_and_loss(operator, 73, [{~D[2026-10-01], ~D[2026-10-31]}])

    assert {:ok, activity} =
             Reports.account_activity(operator, 73, income.id,
               from: ~D[2026-10-01],
               to: ~D[2026-10-31],
               through_entry_number: report.through_entry_number
             )

    assert %{
             account: %{code: "4000", account_type: "income"},
             from: ~D[2026-10-01],
             to: ~D[2026-10-31],
             through_entry_number: 3,
             currency_code: "XTS",
             more?: false
           } = activity

    assert Decimal.equal?(Decimal.sub(activity.credits, activity.debits), hd(row.amounts))
    assert Enum.map(activity.entries, & &1.id) == [first.id, second.id]

    assert [%{debit: debit, credit: credit, posted_by_user_id: 91, lines: [_, _]} | _] =
             activity.entries

    assert Decimal.equal?(debit, 0) and Decimal.equal?(credit, 300)
  end

  test "an entry's own amount sums its lines on the account", context do
    %{operator: operator, accounts: accounts, entries: [_first, second, _november]} = context

    assert {:ok, %{entries: [entry]}} =
             Reports.account_activity(operator, 73, accounts["1020"].id)

    assert entry.id == second.id
    assert Decimal.equal?(entry.debit, 20) and length(entry.lines) == 3
  end

  test "keeps to the entries the pinned figure counted", context do
    %{operator: operator, accounts: accounts, entries: entries} = context

    TestFixtures.post!(operator, accounts, ~D[2026-10-15], [
      {"1010", :debit, "5"},
      {"4000", :credit, "5"}
    ])

    assert {:ok, pinned} =
             Reports.account_activity(operator, 73, accounts["4000"].id, through_entry_number: 3)

    assert Enum.map(pinned.entries, & &1.id) == Enum.map(entries, & &1.id)
    assert Decimal.equal?(pinned.credits, 470)

    assert {:ok, latest} = Reports.account_activity(operator, 73, accounts["4000"].id)
    assert latest.through_entry_number == 4 and length(latest.entries) == 4
  end

  test "pages through the entries in date order", context do
    %{operator: operator, accounts: accounts, entries: [first, second, november]} = context
    income = accounts["4000"].id

    assert {:ok, %{entries: [page_one], more?: true}} =
             Reports.account_activity(operator, 73, income, limit: 1)

    assert page_one.id == first.id

    assert {:ok, %{entries: [page_two, page_three], more?: true}} =
             Reports.account_activity(operator, 73, income,
               limit: 2,
               after: {page_one.entry_date, page_one.id}
             )

    assert {page_two.id, page_three.id} == {second.id, november.id}

    assert {:ok, %{entries: [], more?: false}} =
             Reports.account_activity(operator, 73, income,
               limit: 2,
               after: {page_three.entry_date, page_three.id}
             )
  end

  test "refuses an account of no company of the scope's, and bad options", context do
    %{operator: operator, accounts: accounts, first_scope: system} = context

    assert {:error, :account_not_found} = Reports.account_activity(operator, 73, 9_999_999)
    assert {:error, :account_not_found} = Reports.account_activity(operator, 73, "1")

    for options <- [[from: "2026-10-01"], [limit: 0], [limit: 501], [through_entry_number: -1]] do
      assert {:error, :invalid_option} =
               Reports.account_activity(operator, 73, accounts["4000"].id, options)
    end

    clerk = LedgerFixtures.sign_in!(system, 73, 92, ["finance.ledger.entries.post"])

    assert {:error, :unauthorized} =
             Reports.account_activity(clerk, 73, accounts["4000"].id)
  end
end
