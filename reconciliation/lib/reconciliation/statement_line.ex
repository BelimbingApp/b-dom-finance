defmodule Bilimbi.Finance.Reconciliation.StatementLine do
  @moduledoc false
  use Ecto.Schema

  schema "finance_reconciliation_statement_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:statement_id, :integer)
    field(:bank_account_id, :integer)
    field(:line_number, :integer)
    field(:line_date, :date)
    field(:description, :string)
    field(:reference, :string)
    field(:amount, :decimal)
    field(:running_balance, :decimal)
    field(:fingerprint, :string)
  end
end
