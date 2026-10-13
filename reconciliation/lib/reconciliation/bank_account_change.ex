defmodule Bilimbi.Finance.Reconciliation.BankAccountChange do
  @moduledoc false
  use Ecto.Schema

  # One field of a bank account being changed. Append-only: the database
  # refuses to update or delete a row and stamps `changed_at`.
  schema "finance_reconciliation_bank_account_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:bank_account_id, :integer)
    field(:field, :string)
    field(:old_value, :string)
    field(:new_value, :string)
    field(:reason, :string)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end
end
