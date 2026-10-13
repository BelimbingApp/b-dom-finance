defmodule Bilimbi.Finance.Reconciliation.MatchEntry do
  @moduledoc false
  use Ecto.Schema

  # A ledger entry's side of a match: its debits less its credits on the
  # bank account's ledger account, and the entry's own facts, copied because
  # a posted entry never changes.
  schema "finance_reconciliation_match_entries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:match_id, :integer)
    field(:bank_account_id, :integer)
    field(:entry_id, :integer)
    field(:entry_number, :integer)
    field(:entry_date, :date)
    field(:description, :string)
    field(:reference, :string)
    field(:amount, :decimal)
  end
end
