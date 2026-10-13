defmodule Bilimbi.Finance.Attachments.Retention do
  @moduledoc false
  # The retain-until a source document gets: the company's retention years
  # after the end of the financial year its record falls in. The financial
  # year is the ledger's fiscal year covering the record's date when the
  # company has opened one, else the calendar year; the day ends in UTC.

  alias Bilimbi.Finance.Ledger

  # The migration's default; `test/retention_test.exs` checks they agree.
  @default_years 7

  @doc "The years a company keeps source documents until it sets its own."
  def default_years, do: @default_years

  @doc "The end of the financial year `date` falls in, as the ledger knows it."
  def financial_year_end(scope, company_id, %Date{} = date) do
    with {:ok, years} <- Ledger.list_fiscal_years(scope, company_id) do
      case Enum.find(years, &covers?(&1, date)) do
        nil -> {:ok, Date.new!(date.year, 12, 31)}
        year -> {:ok, year.end_date}
      end
    end
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
