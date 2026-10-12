defmodule Bilimbi.Finance.Ledger.Period do
  @moduledoc false
  use Ecto.Schema

  # One calendar month of a fiscal year. Its status is never stored: it is
  # the latest closing event's (see `Bilimbi.Finance.Ledger.ClosingEvent`).
  schema "finance_ledger_periods" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:fiscal_year_id, :integer)
    field(:period_number, :integer)
    field(:start_date, :date)
    field(:end_date, :date)
  end
end
