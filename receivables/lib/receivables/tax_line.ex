defmodule Bilimbi.Finance.Receivables.TaxLine do
  @moduledoc false
  use Ecto.Schema

  # One row per tax code a document uses, derived from its lines whenever
  # the draft is saved; issuing posts each to the tax code's account.
  schema "finance_receivables_document_tax_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:tax_code_id, :integer)
    field(:tax_code, :string)
    field(:tax_rate, :decimal)
    field(:taxable_amount, :decimal)
    field(:tax_amount, :decimal)
    field(:account_id, :integer)
  end
end
