defmodule Bilimbi.Finance.FixedAssets.Schedule do
  @moduledoc """
  Book depreciation policy: a full charge in the in-service calendar month,
  then monthly, with half-up rounding at the book's precision. Straight line
  spreads depreciable cost equally. Reducing balance uses annual percentage
  divided by twelve on opening carrying value, capped at residual value;
  the final useful-life month clears the remaining depreciable amount.
  """
  def rows(asset, minor_units) do
    depreciable = Decimal.sub(asset.cost, asset.residual_value)
    first = Date.beginning_of_month(asset.in_service_date)

    {rows, _} =
      Enum.map_reduce(1..asset.life_months, Decimal.new(0), fn month, accumulated ->
        remaining = Decimal.sub(depreciable, accumulated)

        amount =
          cond do
            month == asset.life_months ->
              remaining

            asset.method == "straight_line" ->
              Decimal.div(depreciable, asset.life_months)

            true ->
              asset.cost
              |> Decimal.sub(accumulated)
              |> Decimal.mult(asset.annual_rate)
              |> Decimal.div(1200)
          end

        amount =
          amount
          |> Decimal.round(minor_units, :half_up)
          |> Decimal.min(remaining)
          |> Decimal.max(Decimal.new(0))

        total = Decimal.add(accumulated, amount)

        {%{
           period: Date.shift(first, month: month - 1),
           amount: amount,
           accumulated: total,
           carrying_value: Decimal.sub(asset.cost, total)
         }, total}
      end)

    rows
  end

  def cumulative(asset, date, precision) do
    asset
    |> rows(precision)
    |> Enum.filter(&(Date.compare(Date.end_of_month(&1.period), date) != :gt))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))
  end
end
