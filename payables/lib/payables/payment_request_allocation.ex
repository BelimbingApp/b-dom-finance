defmodule Bilimbi.Finance.Payables.PaymentRequestAllocation do
  @moduledoc false
  use Ecto.Schema

  schema "finance_payables_payment_request_allocations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:request_id, :integer)
    field(:line_number, :integer)
    field(:document_id, :integer)
    field(:amount, :decimal)
  end
end
