defmodule Bilimbi.Finance.Reconciliation.ReconciliationItem do
  @moduledoc false
  use Ecto.Schema

  @kinds ~w(statement_line entry timing)

  # One item a finalised reconciliation explained its difference with.
  schema "finance_reconciliation_reconciliation_items" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:reconciliation_id, :integer)
    field(:item_number, :integer)
    field(:kind, :string)
    field(:statement_line_id, :integer)
    field(:entry_id, :integer)
    field(:match_id, :integer)
    field(:item_date, :date)
    field(:description, :string)
    field(:reference, :string)
    field(:amount, :decimal)
  end

  def kinds, do: @kinds
end
