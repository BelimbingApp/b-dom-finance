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
    # The seam for matching a purchase order later: the caller's own ID for
    # the order line, which this module stores and never interprets.
    field(:external_order_line_id, :string)
  end

  def changeset(line, attributes, minor_units) do
    line
    |> cast(attributes, [
      :description,
      :account_id,
      :amount,
      :tax_code_id,
      :external_order_line_id
    ])
    |> update_change(:description, &String.trim/1)
    |> update_change(:external_order_line_id, &String.trim/1)
    |> validate_required([:description, :account_id, :amount])
    |> validate_length(:description, min: 1, max: 500)
    |> validate_length(:external_order_line_id, max: 100)
    |> Amount.validate(:amount, minor_units)
  end
end
