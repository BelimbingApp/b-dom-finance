defmodule Bilimbi.Finance.FixedAssets.ScheduleTest do
  use ExUnit.Case, async: true
  alias Bilimbi.Finance.FixedAssets.Schedule

  test "rounding never depreciates below residual and the last month clears the balance" do
    asset = %{
      cost: Decimal.new("10"),
      residual_value: Decimal.new("1"),
      in_service_date: ~D[2026-01-17],
      method: "straight_line",
      life_months: 7
    }

    rows = Schedule.rows(asset, 2)
    assert length(rows) == 7
    assert hd(rows).period == ~D[2026-01-01]
    assert Decimal.eq?(hd(rows).amount, "1.29")
    assert Decimal.eq?(List.last(rows).carrying_value, 1)
    assert Decimal.eq?(Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.amount, &2)), 9)
    assert Decimal.eq?(Schedule.cumulative(asset, ~D[2026-01-30], 2), 0)
    assert Decimal.eq?(Schedule.cumulative(asset, ~D[2026-01-31], 2), "1.29")
  end
end
