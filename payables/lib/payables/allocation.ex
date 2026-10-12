defmodule Bilimbi.Finance.Payables.Allocation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Payables.Amount

  schema "finance_payables_payment_allocations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:payment_id, :integer)
    field(:line_number, :integer)
    field(:document_id, :integer)
    field(:amount, :decimal)
  end

  def changeset(allocation, attributes, minor_units) do
    allocation
    |> cast(attributes, [:document_id, :amount])
    |> validate_required([:document_id, :amount])
    |> Amount.validate(:amount, minor_units)
  end
end
