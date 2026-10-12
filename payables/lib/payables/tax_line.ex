defmodule Bilimbi.Finance.Payables.TaxLine do
  @moduledoc false
  use Ecto.Schema

  schema "finance_payables_document_tax_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:line_number, :integer)
    field(:tax_code_id, :integer)
    field(:tax_code, :string)
    field(:rate, :decimal)
    field(:account_id, :integer)
    field(:taxable_amount, :decimal)
    field(:tax_amount, :decimal)
  end
end
