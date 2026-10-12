defmodule Bilimbi.Finance.Einvoice.Line do
  @moduledoc false
  use Ecto.Schema

  schema "finance_einvoice_document_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:line_number, :integer)
    field(:description, :string)
    field(:classification_code, :string)
    field(:tariff_code, :string)
    field(:origin_country_code, :string)
    field(:quantity, :decimal)
    field(:unit_code, :string)
    field(:unit_price, :decimal)
    field(:subtotal, :decimal)
    field(:discount_amount, :decimal)
    field(:charge_amount, :decimal)
    field(:line_extension_amount, :decimal)
    field(:tax_type, :string)
    field(:tax_rate, :decimal)
    field(:tax_amount, :decimal)
    field(:tax_exemption_reason, :string)
  end
end
