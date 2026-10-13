defmodule Bilimbi.Finance.Reports.StatementsTest do
  # The contribution registry snapshot is process-global and Base Settings
  # caches by key and scope node-wide, so this suite runs alone.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.TestFixtures, as: SettingsFixtures
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reports
  alias Bilimbi.Finance.Reports.TestFixtures

  @october {~D[2026-10-01], ~D[2026-10-31]}
  @september {~D[2026-09-01], ~D[2026-09-30]}

  setup do
    context = TestFixtures.setup_reports!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    %{operator: operator, accounts: accounts} = context

    for {date, lines} <- [
          {~D[2026-09-15], [{"1010", :debit, "1000"}, {"3000", :credit, "1000"}]},
          {~D[2026-10-03], [{"1020", :debit, "300"}, {"4000", :credit, "300"}]},
          {~D[2026-10-10], [{"5000", :debit, "120"}, {"2000", :credit, "120"}]},
          {~D[2026-10-20], [{"1500", :debit, "50"}, {"4100", :credit, "50"}]},
          {~D[2026-09-20], [{"5100", :debit, "40"}, {"1010", :credit, "40"}]},
          {~D[2026-11-05], [{"1010", :debit, "70"}, {"4000", :credit, "70"}]}
        ] do
      TestFixtures.post!(operator, accounts, date, lines)
    end

    TestFixtures.put_sections!([
      %{"report" => "profit_and_loss", "name" => "Sales", "accounts" => ["4000"]},
      %{"report" => "profit_and_loss", "name" => "Running costs", "accounts" => ["5000", "5100"]},
      %{"report" => "balance_sheet", "name" => "Short-term assets", "accounts" => ["1000"]},
      %{"report" => "cash_position", "name" => "Bank and cash", "accounts" => ["1000", "2100"]}
    ])

    context
  end

  describe "profit_and_loss/4" do
    test "groups income and expense by section against the previous period", %{operator: operator} do
      assert {:ok, report} = Reports.profit_and_loss(operator, 73, [@october, @september])

      assert %{
               currency_code: "XTS",
               minor_units: 2,
               through_entry_number: 6,
               unmatched_codes: [],
               columns: [
                 %{from: ~D[2026-10-01], to: ~D[2026-10-31]},
                 %{from: ~D[2026-09-01], to: ~D[2026-09-30]}
               ]
             } = report

      assert [income, expense] = report.groups
      assert sections(income) == [{"Sales", [{"4000", [300, 0]}]}, {nil, [{"4100", [50, 0]}]}]
      assert sections(expense) == [{"Running costs", [{"5000", [120, 0]}, {"5100", [0, 40]}]}]
      assert amounts(income.totals) == [350, 0]
      assert amounts(expense.totals) == [120, 40]
      assert amounts(report.net_income) == [230, -40]
    end

    test "lists only accounts with postings in some column", %{operator: operator} do
      assert {:ok, %{groups: [income, expense]}} =
               Reports.profit_and_loss(operator, 73, [{~D[2026-11-01], ~D[2026-11-30]}])

      assert sections(income) == [{"Sales", [{"4000", [70]}]}]
      assert expense.sections == []
      assert amounts(expense.totals) == [0]
    end
  end

  describe "balance_sheet/4" do
    test "balances with the income and expense not yet closed", %{operator: operator} do
      assert {:ok, report} =
               Reports.balance_sheet(operator, 73, [~D[2026-10-31], ~D[2026-09-30]])

      assert report.columns == [%{as_of: ~D[2026-10-31]}, %{as_of: ~D[2026-09-30]}]
      assert [assets, liabilities, equity] = report.groups

      # 1000 has no postings of its own; its sub-accounts follow it into the
      # section, and 1500, which no section covers, comes after.
      assert sections(assets) == [
               {"Short-term assets", [{"1010", [960, 960]}, {"1020", [300, 0]}]},
               {nil, [{"1500", [50, 0]}]}
             ]

      assert sections(liabilities) == [{nil, [{"2000", [120, 0]}]}]
      assert sections(equity) == [{nil, [{"3000", [1000, 1000]}]}]
      assert amounts(report.earnings) == [190, -40]
      assert amounts(equity.totals) == [1190, 960]
      assert amounts(report.total_assets) == [1310, 960]
      assert report.total_liabilities_and_equity == report.total_assets
    end

    test "reproduces an earlier sheet exactly after a back-dated posting", context do
      %{operator: operator, accounts: accounts} = context
      dates = [~D[2026-10-31], ~D[2026-09-30]]

      assert {:ok, %{through_entry_number: 6} = earlier} =
               Reports.balance_sheet(operator, 73, dates)

      TestFixtures.post!(operator, accounts, ~D[2026-10-15], [
        {"5000", :debit, "10"},
        {"1010", :credit, "10"}
      ])

      assert {:ok, %{through_entry_number: 7, groups: [assets | _]}} =
               Reports.balance_sheet(operator, 73, dates)

      assert {"Short-term assets", [{"1010", [950, 960]} | _]} = hd(sections(assets))

      assert {:ok, ^earlier} =
               Reports.balance_sheet(operator, 73, dates, through_entry_number: 6)
    end

    test "names the configured codes the chart does not have", %{operator: operator} do
      TestFixtures.put_sections!([
        %{
          "report" => "balance_sheet",
          "name" => "Short-term assets",
          "accounts" => ["1000", "9999"]
        }
      ])

      assert {:ok, %{unmatched_codes: ["9999"]}} =
               Reports.balance_sheet(operator, 73, [~D[2026-10-31]])
    end
  end

  describe "cash_position/4" do
    test "lists every covered account, overdrawn ones counting against the total",
         %{operator: operator, accounts: accounts} do
      TestFixtures.post!(operator, accounts, ~D[2026-10-25], [
        {"5100", :debit, "400"},
        {"2100", :credit, "400"}
      ])

      assert {:ok, report} =
               Reports.cash_position(operator, 73, [~D[2026-10-31], ~D[2026-09-30]])

      assert [{"Bank and cash", rows}] = Enum.map(report.sections, &{&1.name, rows(&1)})

      assert rows == [
               {"1000", [0, 0]},
               {"1010", [960, 960]},
               {"1020", [300, 0]},
               {"2100", [-400, 0]}
             ]

      assert amounts(report.totals) == [860, 960]
    end

    test "is empty until the company names its cash accounts", %{operator: operator} do
      TestFixtures.put_sections!([])

      assert {:ok, %{sections: [], totals: [total]}} =
               Reports.cash_position(operator, 73, [~D[2026-10-31]])

      assert Decimal.equal?(total, 0)
    end
  end

  test "overview gives the headline figures of a period and the one before it",
       %{operator: operator} do
    assert {:ok, overview} = Reports.overview(operator, 73, @october)

    assert overview.columns == [
             %{from: ~D[2026-10-01], to: ~D[2026-10-31]},
             %{from: ~D[2026-09-01], to: ~D[2026-09-30]}
           ]

    assert %{through_entry_number: 6, currency_code: "XTS"} = overview

    for {figure, expected} <- [
          income: [350, 0],
          expense: [120, 40],
          net_income: [230, -40],
          assets: [1310, 960],
          liabilities: [120, 0],
          equity: [1190, 960],
          cash: [1260, 960]
        ] do
      assert amounts(Map.fetch!(overview, figure)) == expected, "#{figure}"
    end
  end

  test "a closed year's profit and loss still shows its activity, its result now in equity",
       %{first_scope: system} do
    closer =
      LedgerFixtures.sign_in!(system, 73, 94, [
        "finance.ledger.view",
        "finance.ledger.accounts.manage",
        "finance.ledger.entries.post",
        "finance.ledger.periods.manage"
      ])

    {:ok, retained} =
      Bilimbi.Finance.Ledger.create_account(closer, 73, %{
        code: "3900",
        name: "Account 3900",
        account_type: "equity",
        retained_earnings: true
      })

    {:ok, years} = Bilimbi.Finance.Ledger.list_fiscal_years(closer, 73)
    [year] = Enum.filter(years, &(&1.start_date == ~D[2026-01-01]))

    {:ok, %{closing_entry_id: closing}} =
      Bilimbi.Finance.Ledger.close_fiscal_year(closer, 73, year.id)

    assert closing

    assert {:ok, %{groups: [income, expense], net_income: net_income}} =
             Reports.profit_and_loss(closer, 73, [{~D[2026-01-01], ~D[2026-12-31]}])

    assert amounts(income.totals) == [420]
    assert amounts(expense.totals) == [160]
    assert amounts(net_income) == [260]

    assert {:ok, sheet} = Reports.balance_sheet(closer, 73, [~D[2026-12-31]])
    assert amounts(sheet.earnings) == [0]
    assert [_assets, _liabilities, equity] = sheet.groups
    assert {nil, [{"3000", [1000]}, {"3900", [260]}]} = hd(sections(equity))
    assert amounts(sheet.total_assets) == [1380]
    assert sheet.total_liabilities_and_equity == sheet.total_assets
    assert retained.retained_earnings
  end

  # A value stored before validation, or adopted, is never trusted.
  test "a malformed layout groups nothing rather than wrongly", %{operator: operator} do
    scope = Settings.Scope.company(73, 41)
    :ok = Settings.delete("finance.reports.sections", scope)

    SettingsFixtures.put_stored_value!(
      "finance.reports.sections",
      [%{"report" => "balance_sheet", "name" => "", "accounts" => ["1000"]}],
      scope
    )

    assert {:ok, %{groups: [assets | _]}} = Reports.balance_sheet(operator, 73, [~D[2026-10-31]])
    assert [{nil, _rows}] = sections(assets)
  end

  test "refuses malformed periods, dates and entry numbers", %{operator: operator} do
    for periods <- [
          [],
          List.duplicate(@october, 5),
          [{~D[2026-10-31], ~D[2026-10-01]}],
          [:october]
        ] do
      assert {:error, :invalid_option} = Reports.profit_and_loss(operator, 73, periods)
    end

    for dates <- [[], ["2026-10-31"], List.duplicate(~D[2026-10-31], 5)] do
      assert {:error, :invalid_option} = Reports.balance_sheet(operator, 73, dates)
      assert {:error, :invalid_option} = Reports.cash_position(operator, 73, dates)
    end

    assert {:error, :invalid_option} =
             Reports.balance_sheet(operator, 73, [~D[2026-10-31]], through_entry_number: -1)

    assert {:error, :invalid_option} =
             Reports.overview(operator, 73, {~D[2026-10-31], ~D[2026-10-01]})
  end

  test "needs the ledger view grant on a company the scope can see", %{first_scope: system} do
    clerk = LedgerFixtures.sign_in!(system, 73, 92, ["finance.ledger.entries.post"])
    assert {:error, :unauthorized} = Reports.profit_and_loss(clerk, 73, [@october])
    assert {:error, :unauthorized} = Reports.balance_sheet(clerk, 73, [~D[2026-10-31]])
    assert {:error, :unauthorized} = Reports.cash_position(clerk, 73, [~D[2026-10-31]])
    assert {:error, :unauthorized} = Reports.overview(clerk, 73, @october)
    assert {:error, :unauthorized} = Reports.balance_sheet(system, 73, [~D[2026-10-31]])

    sibling = LedgerFixtures.sign_in!(system, 74, 93, ["finance.ledger.view"])
    assert {:error, :book_not_open} = Reports.balance_sheet(sibling, 74, [~D[2026-10-31]])
    assert {:error, :unauthorized} = Reports.balance_sheet(sibling, 73, [~D[2026-10-31]])
    assert {:error, :company_not_found} = Reports.balance_sheet(sibling, 75, [~D[2026-10-31]])
  end

  defp sections(group), do: Enum.map(group.sections, &{&1.name, rows(&1)})

  defp rows(section), do: Enum.map(section.rows, &{&1.code, amounts(&1.amounts)})

  # Decimal amounts as integers for comparison; every amount here is whole.
  defp amounts(values) do
    Enum.map(values, fn value ->
      integer = Decimal.to_integer(Decimal.round(value, 0))
      if Decimal.equal?(value, integer), do: integer, else: value
    end)
  end
end
