defmodule Bilimbi.Finance.Einvoice.Document do
  @moduledoc false
  use Ecto.Schema

  alias Bilimbi.Finance.Einvoice.Line

  schema "finance_einvoice_documents" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:authority, :string)
    field(:environment, :string)
    field(:document_type, :string)
    field(:code_number, :string)
    field(:issued_at, :utc_datetime)
    field(:currency_code, :string)
    field(:exchange_rate, :decimal)
    field(:supplier, :map)
    field(:buyer, :map)
    field(:details, :map, default: %{})
    field(:original_document_id, :integer)
    field(:line_extension_amount, :decimal)
    field(:tax_exclusive_amount, :decimal)
    field(:tax_amount, :decimal)
    field(:tax_inclusive_amount, :decimal)
    field(:payable_amount, :decimal)
    field(:issued_by_user_id, :integer)
    field(:issued_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, Line)
  end
end
