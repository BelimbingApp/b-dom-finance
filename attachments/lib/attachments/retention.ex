defmodule Bilimbi.Finance.Attachments.Retention do
  @moduledoc false
  # The retain-until a source document gets: the company's retention years
  # after the end of the financial year its record falls in. The financial
  # year is the ledger's fiscal year covering the record's date; a date no
  # opened year covers takes the company's own year end projected in twelve-
  # month steps from the nearest opened year (forward from the last year
  # ending before it, else backward from the first), so a retain-until is
  # never shorter than the statutory one. Only a company with no fiscal year
  # at all takes 31 December of the date's year. The day ends in UTC.

  alias Bilimbi.Finance.Ledger

  # The migration's default; `test/retention_test.exs` checks they agree.
  @default_years 7

  @doc "The years a company keeps source documents until it sets its own."
  def default_years, do: @default_years

  @doc "The end of the financial year `date` falls in, as the ledger knows it."
  def financial_year_end(scope, company_id, %Date{} = date) do
    with {:ok, years} <- Ledger.list_fiscal_years(scope, company_id) do
      {:ok, year_end(years, date)}
    end
  end

  defp year_end([], date), do: Date.new!(date.year, 12, 31)

  defp year_end([first | _] = years, date) do
    case Enum.find(years, &covers?(&1, date)) do
      %{end_date: year_end} -> year_end
      nil -> project(years, first, date)
    end
  end

  defp project(years, first, date) do
    case years |> Enum.filter(&(Date.compare(&1.end_date, date) == :lt)) |> List.last() do
      nil -> project_back(first.start_date, date, 1)
      previous -> project_forward(previous.end_date, date, 1)
    end
  end

  defp project_forward(base, date, steps) do
    year_end = Date.shift(base, month: 12 * steps)

    if Date.compare(year_end, date) == :lt,
      do: project_forward(base, date, steps + 1),
      else: year_end
  end

  defp project_back(base, date, steps) do
    start = Date.shift(base, month: -12 * steps)

    if Date.compare(start, date) == :gt,
      do: project_back(base, date, steps + 1),
      else: base |> Date.shift(month: -12 * (steps - 1)) |> Date.add(-1)
  end

  @doc "`years` after the end of the financial year, at the end of that day in UTC."
  def retain_until(scope, company_id, %Date{} = date, years)
      when is_integer(years) and years > 0 do
    with {:ok, year_end} <- financial_year_end(scope, company_id, date) do
      {:ok, until(year_end, years)}
    end
  end

  @doc "The end of the day `years` after `year_end`, in UTC."
  def until(%Date{} = year_end, years) when is_integer(years) and years > 0,
    do: year_end |> Date.shift(year: years) |> end_of_day()

  @doc "The last instant of `date` in UTC, at the microsecond Base Artifacts stores."
  def end_of_day(%Date{} = date), do: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")

  defp covers?(%{start_date: first, end_date: last}, date),
    do: Date.compare(first, date) != :gt and Date.compare(last, date) != :lt
end
