defmodule Bilimbi.Finance.Receivables.Allocation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Receivables.Payment

  @amount_limit Decimal.new("1E16")

  schema "finance_receivables_allocations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:payment_id, :integer)
    field(:document_id, :integer)
    field(:amount, :decimal)
  end

  def changeset(allocation, attributes, minor_units) do
    allocation
    |> cast(attributes, [:document_id, :amount])
    |> validate_required([:document_id, :amount])
    |> validate_number(:amount, greater_than: 0, less_than: @amount_limit)
    |> Payment.validate_minor_units(:amount, minor_units)
  end
end
