defmodule Bilimbi.Finance.Ledger.FiscalYear do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Ledger.Period

  # A year runs whole calendar months, from one month to two years.
  @max_months 24

  schema "finance_ledger_fiscal_years" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:opened_by_user_id, :integer)
    field(:opened_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:opened_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:periods, Period)
  end

  @doc """
  Casts a new fiscal year after `previous`, the company's latest year or
  `nil`. A later year starts the day after `previous` ends, which is also its
  default start; the end defaults to twelve months on.
  """
  def changeset(year, attributes, previous) do
    year
    |> cast(attributes, [:start_date, :end_date])
    |> default_start(previous)
    |> default_end()
    |> validate_required([:tenant_id, :company_id, :start_date, :end_date, :opened_by_user_id])
    |> validate_follows(previous)
    |> validate_months()
    |> unique_constraint(:start_date, name: :finance_ledger_fiscal_years_company_start_unique)
  end

  @doc "The year's months as `{period_number, start_date, end_date}`."
  def months(%{start_date: start_date, end_date: end_date}) do
    start_date
    |> Stream.iterate(&Date.shift(&1, month: 1))
    |> Stream.take_while(&(Date.compare(&1, end_date) != :gt))
    |> Stream.with_index(1)
    |> Enum.map(fn {first, number} -> {number, first, Date.end_of_month(first)} end)
  end

  defp default_start(changeset, nil), do: changeset

  defp default_start(changeset, previous) do
    if get_field(changeset, :start_date),
      do: changeset,
      else: put_change(changeset, :start_date, Date.add(previous.end_date, 1))
  end

  defp default_end(changeset) do
    case {get_field(changeset, :start_date), get_field(changeset, :end_date)} do
      {%Date{} = start, nil} ->
        put_change(changeset, :end_date, start |> Date.shift(month: 12) |> Date.add(-1))

      _given ->
        changeset
    end
  end

  defp validate_follows(changeset, nil), do: changeset

  defp validate_follows(changeset, previous) do
    expected = Date.add(previous.end_date, 1)

    validate_change(changeset, :start_date, fn :start_date, start ->
      if start == expected,
        do: [],
        else: [start_date: "must be #{expected}, the day after the previous fiscal year ends"]
    end)
  end

  defp validate_months(changeset) do
    start = get_field(changeset, :start_date)
    finish = get_field(changeset, :end_date)

    cond do
      not (match?(%Date{}, start) and match?(%Date{}, finish)) ->
        changeset

      start.day != 1 ->
        add_error(changeset, :start_date, "must be the first day of a month")

      Date.add(finish, 1).day != 1 ->
        add_error(changeset, :end_date, "must be the last day of a month")

      Date.compare(finish, start) != :gt or
          Date.compare(finish, Date.shift(start, month: @max_months)) != :lt ->
        add_error(changeset, :end_date, "must end one to #{@max_months} months after the start")

      true ->
        changeset
    end
  end
end
