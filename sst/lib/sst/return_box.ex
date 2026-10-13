defmodule Bilimbi.Finance.Sst.ReturnBox do
  @moduledoc false
  use Ecto.Schema

  # A finalised return's figure for one box, in the form's order.
  schema "finance_sst_return_boxes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:return_id, :integer)
    field(:line_number, :integer)
    field(:box, :string)
    field(:taxable_amount, :decimal)
    field(:tax_amount, :decimal)
  end
end
