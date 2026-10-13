defmodule Bilimbi.Finance.Reconciliation.ReconciliationRecord do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Reconciliation.{ReconciliationEvent, ReconciliationItem}

  # One reconciliation of a bank account as of a statement end date. The
  # database numbers and stamps it (see the migration).
  schema "finance_reconciliation_reconciliations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:bank_account_id, :integer)
    field(:reconciliation_number, :integer, read_after_writes: true)
    field(:end_date, :date)
    field(:statement_balance, :decimal)
    field(:opened_by_user_id, :integer)
    field(:opened_by_impersonator_id, :integer)
    field(:opened_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:events, ReconciliationEvent, foreign_key: :reconciliation_id)
    has_many(:items, ReconciliationItem, foreign_key: :reconciliation_id)
  end

  def changeset(reconciliation, attributes, minor_units) do
    reconciliation
    |> cast(attributes, [:end_date, :statement_balance])
    |> validate_required([
      :tenant_id,
      :company_id,
      :bank_account_id,
      :end_date,
      :statement_balance,
      :opened_by_user_id
    ])
    |> validate_change(:statement_balance, fn :statement_balance, balance ->
      if Decimal.equal?(balance, Decimal.round(balance, minor_units)),
        do: [],
        else: [statement_balance: "has more decimal places than the book's currency"]
    end)
  end
end
