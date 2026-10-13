defmodule Bilimbi.Finance.Payables.DocumentLine do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Payables.Amount

  schema "finance_payables_document_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:line_number, :integer)
    field(:description, :string)
    field(:account_id, :integer)
    field(:amount, :decimal)
    field(:tax_code_id, :integer)
    # The caller's own reference for an order line, which this module stores
    # and never interprets.
    field(:external_order_line_id, :string)
    # A purchase order line of the installed order source
    # (`Bilimbi.Finance.Payables.OrderSource`), and the quantity billed
    # against it; posting matches the two against the order and its receipts.
    field(:order_line_id, :integer)
    field(:quantity, :decimal)
  end

  def changeset(line, attributes, minor_units) do
    line
    |> cast(attributes, [
      :description,
      :account_id,
      :amount,
      :tax_code_id,
      :external_order_line_id,
      :order_line_id,
      :quantity
    ])
    |> update_change(:description, &String.trim/1)
    |> update_change(:external_order_line_id, &String.trim/1)
    |> validate_required([:description, :account_id, :amount])
    |> validate_length(:description, min: 1, max: 500)
    |> validate_length(:external_order_line_id, max: 100)
    |> Amount.validate(:amount, minor_units)
    |> validate_number(:order_line_id, greater_than: 0)
    |> Amount.validate(:quantity, 4)
    |> validate_order_reference()
  end

  # The order line and the quantity billed against it come together.
  defp validate_order_reference(changeset) do
    case {get_field(changeset, :order_line_id), get_field(changeset, :quantity)} do
      {nil, nil} -> changeset
      {nil, _quantity} -> add_error(changeset, :order_line_id, "is needed with a quantity")
      {_order_line_id, nil} -> add_error(changeset, :quantity, "is needed with an order line")
      _both -> changeset
    end
  end
end
