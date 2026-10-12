defmodule Bilimbi.Finance.Receivables.Payment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Receivables.{Allocation, PaymentReversal}

  # The column is numeric(20, 4): sixteen digits before the point.
  @amount_limit Decimal.new("1E16")

  schema "finance_receivables_payments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:series_id, :integer)
    field(:customer_id, :integer)
    field(:payment_number, :integer)
    field(:payment_reference, :string)
    field(:payment_date, :date)
    field(:amount, :decimal)
    field(:currency_code, :string)
    field(:deposit_account_id, :integer)
    field(:reference, :string)
    field(:description, :string)
    field(:ledger_entry_id, :integer)
    field(:ledger_entry_number, :integer)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:allocations, Allocation)
    has_one(:reversal, PaymentReversal)
  end

  def changeset(payment, attributes, minor_units) do
    payment
    |> cast(attributes, [
      :series_id,
      :customer_id,
      :payment_date,
      :amount,
      :deposit_account_id,
      :reference,
      :description
    ])
    |> update_change(:reference, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :currency_code,
      :series_id,
      :customer_id,
      :payment_date,
      :amount,
      :deposit_account_id,
      :recorded_by_user_id
    ])
    |> validate_number(:amount, greater_than: 0, less_than: @amount_limit)
    |> validate_minor_units(:amount, minor_units)
    |> validate_length(:reference, max: 100)
    |> validate_length(:description, max: 500)
  end

  @doc "Refuses an amount finer than the book's minor units instead of rounding it."
  def validate_minor_units(changeset, field, minor_units) do
    validate_change(changeset, field, fn ^field, amount ->
      if Decimal.equal?(Decimal.round(amount, minor_units), amount),
        do: [],
        else: [{field, "has more than #{minor_units} decimal places"}]
    end)
  end
end
