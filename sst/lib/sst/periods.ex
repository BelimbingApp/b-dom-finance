defmodule Bilimbi.Finance.Sst.Periods do
  @moduledoc """
  Taxable periods and return due dates under a registration's cycle.

  The first period of a cycle runs from its `period_start` to the end of
  the month `period_months` months on, counting the start's own month, as
  section 25(1) of the Sales Tax Act 2018 and of the Service Tax Act 2018
  set the first period: from the date a person is registered to the end of
  the month after it, for the usual two months. Each later period is
  `period_months` whole calendar months.

  A return is due on the last day of the month after its period ends
  (section 26(1) of both Acts) on the usual two-month cycle, and 30 days
  after the period ends on a cycle the Director General varied
  (section 26(2)). A due date that falls on a weekend or public holiday
  moves to the next working day in practice; holidays are not this
  module's data, so the date shown is the statutory one.
  """

  @doc "The period that starts on `start` under the cycle, or `:error` when none does."
  @spec period(map(), Date.t()) :: {:ok, Date.t(), Date.t()} | :error
  def period(%{period_start: first, period_months: months}, %Date{} = start) do
    first_end = month_end(first, months - 1)

    cond do
      start == first ->
        {:ok, first, first_end}

      Date.compare(start, first_end) == :gt and start.day == 1 and
          rem(months_between(first, start) - months, months) == 0 ->
        {:ok, start, month_end(start, months - 1)}

      true ->
        :error
    end
  end

  @doc "The period of the cycle that contains `date`, or `:error` when `date` precedes the cycle."
  @spec containing(map(), Date.t()) :: {:ok, Date.t(), Date.t()} | :error
  def containing(%{period_start: first, period_months: months} = cycle, %Date{} = date) do
    first_end = month_end(first, months - 1)

    cond do
      Date.compare(date, first) == :lt ->
        :error

      Date.compare(date, first_end) != :gt ->
        {:ok, first, first_end}

      true ->
        offset = div(months_between(first, date) - months, months) * months + months
        period(cycle, Date.shift(Date.beginning_of_month(first), month: offset))
    end
  end

  @doc """
  Up to `count` periods of the cycle, newest first, ending with the one
  that contains `date` (or the cycle's first, when `date` precedes it).
  """
  @spec recent(map(), Date.t(), pos_integer()) :: [{Date.t(), Date.t()}]
  def recent(%{period_start: first} = cycle, %Date{} = date, count) when count > 0 do
    {:ok, start, finish} =
      case containing(cycle, date) do
        :error -> period(cycle, first)
        found -> found
      end

    Stream.unfold({start, finish}, fn
      nil ->
        nil

      {start, _finish} = current ->
        previous =
          if start == first,
            do: nil,
            else: containing(cycle, Date.add(start, -1))

        {current,
         case previous do
           {:ok, s, f} -> {s, f}
           _none -> nil
         end}
    end)
    |> Enum.take(count)
  end

  @doc "The statutory due date of a return for a period ending on `period_end`."
  @spec due_date(map(), Date.t()) :: Date.t()
  def due_date(%{period_months: 2}, %Date{} = period_end),
    do: Date.end_of_month(Date.add(period_end, 1))

  def due_date(%{period_months: _varied}, %Date{} = period_end), do: Date.add(period_end, 30)

  defp month_end(date, months_on),
    do: date |> Date.beginning_of_month() |> Date.shift(month: months_on) |> Date.end_of_month()

  defp months_between(from, to), do: (to.year - from.year) * 12 + to.month - from.month
end
