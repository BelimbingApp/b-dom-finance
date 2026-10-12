defmodule Bilimbi.Finance.Payables.Payment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Payables.Allocation

  schema "finance_payables_payments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The database assigns both on insert (see the migration).
    field(:payment_number, :integer, read_after_writes: true)
    field(:payment_date, :date)
    field(:party_key, :string)
    field(:party_name, :string)
    field(:paid_from_account_id, :integer)
    field(:amount, :decimal)
    field(:currency_code, :string)
    field(:reference, :string)
    field(:description, :string)
    field(:reverses_payment_id, :integer)
    field(:entry_id, :integer)
    field(:entry_number, :integer)
    field(:posted_by_user_id, :integer)
    field(:posted_by_impersonator_id, :integer)
    field(:posted_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:allocations, Allocation)
  end

  def changeset(payment, attributes) do
    payment
    |> cast(attributes, [
      :payment_date,
      :party_key,
      :party_name,
      :paid_from_account_id,
      :reference,
      :description
    ])
    |> update_change(:party_key, &String.trim/1)
    |> update_change(:party_name, &String.trim/1)
    |> update_change(:reference, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :payment_date,
      :party_key,
      :party_name,
      :paid_from_account_id,
      :currency_code,
      :posted_by_user_id
    ])
    |> validate_length(:party_key, min: 1, max: 100)
    |> validate_length(:party_name, min: 1, max: 200)
    |> validate_length(:reference, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:reverses_payment_id, name: :finance_payables_payments_reversed_once)
  end
end
