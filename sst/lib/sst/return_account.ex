defmodule Bilimbi.Finance.Sst.ReturnAccount do
  @moduledoc false
  use Ecto.Schema

  # How a finalised return's document tax compared with one tax account.
  schema "finance_sst_return_accounts" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:return_id, :integer)
    field(:line_number, :integer)
    field(:account_id, :integer)
    field(:account_code, :string)
    field(:account_name, :string)
    field(:ledger_debits, :decimal)
    field(:ledger_credits, :decimal)
    field(:document_debits, :decimal)
    field(:document_credits, :decimal)
    field(:difference, :decimal)
  end
end
