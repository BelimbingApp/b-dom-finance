defmodule Bilimbi.Finance.Receivables.PaymentReversal do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_receivables_payment_reversals" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:payment_id, :integer)
    field(:reversal_date, :date)
    field(:reason, :string)
    field(:ledger_entry_id, :integer)
    field(:ledger_entry_number, :integer)
    field(:reversed_by_user_id, :integer)
    field(:reversed_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:reversed_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(reversal, attributes) do
    reversal
    |> cast(attributes, [:reversal_date, :reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:reversal_date, :reason])
    |> validate_length(:reason, min: 1, max: 500)
    |> unique_constraint(:payment_id, name: :finance_receivables_payment_reversals_payment_unique)
  end
end
