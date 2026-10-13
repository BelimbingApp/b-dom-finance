defmodule Bilimbi.Finance.Reports.IssuedReportsTest do
  use Bilimbi.Finance.Reports.IssuedCase, async: false

  test "issued cash preserves membership, labels, figures and issuer when live pinned cash changes",
       context do
    %{operator: operator, accounts: accounts} = context

    TestFixtures.put_sections!([
      %{"report" => "cash_position", "name" => "Operating funds", "accounts" => ["1000"]}
    ])

    TestFixtures.post!(operator, accounts, ~D[2026-10-01], [
      {"1010", :debit, "123.45"},
      {"3000", :credit, "123.45"}
    ])

    assert {:ok, live} = Reports.cash_position(operator, 73, [~D[2026-10-31]])
    assert {:ok, issued} = Reports.issue_report(operator, 73, :cash_position, [~D[2026-10-31]])
    assert issued.content["totals"] == ["123.4500"]
    assert issued.content["sections"] |> hd() |> Map.get("name") == "Operating funds"
    assert issued.issued_by_user_id == 91
    assert issued.implementation_version == "1"
    assert issued.membership["account_sections"][to_string(accounts["1010"].id)] == 0
    assert issued.issued_at

    TestFixtures.put_sections!([])
    assert {:ok, _} = Ledger.update_account(operator, 73, accounts["1010"].id, %{name: "Renamed"})

    assert {:ok, changed} =
             Reports.cash_position(operator, 73, [~D[2026-10-31]],
               through_entry_number: live.through_entry_number
             )

    assert Enum.all?(changed.totals, &Decimal.equal?(&1, 0))
    assert {:ok, ^issued} = Reports.get_issued_report(operator, 73, issued.id)
    assert Enum.find(issued.chart, &(&1["id"] == accounts["1010"].id))["name"] == "Account 1010"
  end

  test "all supported issued report kinds reopen their exact content", %{operator: operator} do
    for {kind, dates} <- [
          profit_and_loss: [{~D[2026-10-01], ~D[2026-10-31]}],
          balance_sheet: [~D[2026-10-31]],
          cash_position: [~D[2026-10-31]],
          trial_balance: ~D[2026-10-31],
          aged_receivables: ~D[2026-10-31],
          aged_payables: ~D[2026-10-31]
        ] do
      assert {:ok, issued} = Reports.issue_report(operator, 73, kind, dates)
      assert {:ok, ^issued} = Reports.get_issued_report(operator, 73, issued.id)
    end
  end

  test "issued reads and writes refuse ungranted, sibling and cross-tenant scopes", context do
    %{operator: operator, first_scope: first, second_scope: second} = context
    assert {:ok, issued} = Reports.issue_report(operator, 73, :balance_sheet, [~D[2026-10-31]])
    clerk = Ledger.TestFixtures.sign_in!(first, 73, 92, ["finance.ledger.view"])

    assert {:error, :unauthorized} =
             Reports.issue_report(clerk, 73, :balance_sheet, [~D[2026-10-31]])

    sibling =
      Ledger.TestFixtures.sign_in!(first, 74, 93, ["finance.ledger.view", "finance.reports.issue"])

    other =
      Ledger.TestFixtures.sign_in!(second, 75, 94, [
        "finance.ledger.view",
        "finance.reports.issue"
      ])

    assert {:error, :unauthorized} = Reports.get_issued_report(sibling, 73, issued.id)
    assert {:error, :company_not_found} = Reports.get_issued_report(other, 73, issued.id)
    assert {:error, :unauthorized} = Reports.get_issued_report(first, 73, issued.id)
  end

  test "an existing transaction cannot pretend to freeze report metadata", %{operator: operator} do
    assert {:error, :transaction_already_open} =
             Repo.transact(fn ->
               Reports.issue_report(operator, 73, :balance_sheet, [~D[2026-10-31]])
             end)
  end
end
