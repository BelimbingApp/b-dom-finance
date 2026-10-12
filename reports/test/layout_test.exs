defmodule Bilimbi.Finance.Reports.LayoutTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Finance.Reports
  alias Bilimbi.Finance.Reports.Layout

  describe "valid_sections?/1" do
    test "accepts sections of a known report with a name and account codes" do
      assert Reports.valid_sections?([])

      assert Reports.valid_sections?([
               %{"report" => "profit_and_loss", "name" => "Sales", "accounts" => ["4000"]},
               %{"report" => "balance_sheet", "name" => "Fixed", "accounts" => []},
               %{"report" => "cash_position", "name" => "Banks", "accounts" => ["1010", "1020"]}
             ])
    end

    test "refuses anything else" do
      for value <- [
            nil,
            %{"report" => "balance_sheet", "name" => "Fixed", "accounts" => []},
            [%{"report" => "trial_balance", "name" => "Other", "accounts" => []}],
            [%{"report" => "balance_sheet", "name" => " ", "accounts" => []}],
            [
              %{
                "report" => "balance_sheet",
                "name" => String.duplicate("x", 101),
                "accounts" => []
              }
            ],
            [%{"report" => "balance_sheet", "name" => "Fixed", "accounts" => [1500]}],
            [%{"report" => "balance_sheet", "name" => "Fixed", "accounts" => [""]}],
            [%{"report" => "balance_sheet", "name" => "Fixed"}],
            [%{"report" => "balance_sheet", "name" => "Fixed", "accounts" => [], "extra" => 1}],
            [%{report: "balance_sheet", name: "Fixed", accounts: []}]
          ] do
        refute Reports.valid_sections?(value), inspect(value)
      end
    end
  end

  test "the nearest listed account decides, and the first section listing a code keeps it" do
    accounts = [
      %{id: 1, code: "1000", parent_id: nil},
      %{id: 2, code: "1010", parent_id: 1},
      %{id: 3, code: "1011", parent_id: 2},
      %{id: 4, code: "1020", parent_id: 1},
      %{id: 5, code: "2000", parent_id: nil}
    ]

    sections = [
      %{name: "Group", codes: ["1000", "9999"]},
      %{name: "Narrow", codes: ["1010"]},
      %{name: "Again", codes: ["1000"]}
    ]

    assert {%{1 => 0, 2 => 1, 3 => 1, 4 => 0}, ["9999"]} = Layout.assign(accounts, sections)
  end

  describe "previous_period/1" do
    test "whole months compare with as many whole months before" do
      assert Reports.previous_period({~D[2026-10-01], ~D[2026-10-31]}) ==
               {~D[2026-09-01], ~D[2026-09-30]}

      assert Reports.previous_period({~D[2026-07-01], ~D[2026-09-30]}) ==
               {~D[2026-04-01], ~D[2026-06-30]}

      assert Reports.previous_period({~D[2026-03-01], ~D[2026-03-31]}) ==
               {~D[2026-02-01], ~D[2026-02-28]}

      assert Reports.previous_period({~D[2026-01-01], ~D[2026-12-31]}) ==
               {~D[2025-01-01], ~D[2025-12-31]}
    end

    test "any other period compares with as many days before" do
      assert Reports.previous_period({~D[2026-10-01], ~D[2026-10-15]}) ==
               {~D[2026-09-16], ~D[2026-09-30]}

      assert Reports.previous_period({~D[2026-10-12], ~D[2026-10-12]}) ==
               {~D[2026-10-11], ~D[2026-10-11]}
    end
  end
end
