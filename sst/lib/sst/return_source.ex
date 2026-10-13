defmodule Bilimbi.Finance.Sst.ReturnSource do
  @moduledoc false
  use Ecto.Schema

  # What a finalised return counted from one source row and where it went.
  schema "finance_sst_return_sources" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:return_id, :integer)
    field(:line_number, :integer)
    field(:source, :string)
    field(:document_kind, :string)
    field(:measure, :string)
    field(:prior_period, :boolean)
    field(:tax_code_id, :integer)
    field(:tax_code, :string)
    field(:rate, :decimal)
    field(:account_id, :integer)
    field(:box, :string)
    field(:mapping_number, :integer)
    field(:document_count, :integer)
    field(:taxable_amount, :decimal)
    field(:tax_amount, :decimal)
  end
end
