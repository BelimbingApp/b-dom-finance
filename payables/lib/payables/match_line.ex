defmodule Bilimbi.Finance.Payables.MatchLine do
  @moduledoc false
  use Ecto.Schema

  alias Bilimbi.Finance.Payables.MatchException

  schema "finance_payables_match_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:event_id, :integer)
    field(:document_id, :integer)
    field(:line_number, :integer)
    field(:order_line_id, :integer)
    field(:order_number, :integer)
    field(:billed_quantity, :decimal)
    field(:billed_unit_price, :decimal)
    field(:previously_billed_quantity, :decimal)
    field(:ordered_quantity, :decimal)
    field(:ordered_unit_price, :decimal)
    field(:received_quantity, :decimal)
    field(:quantity_tolerance_kind, :string)
    field(:quantity_tolerance, :decimal)
    field(:price_tolerance_kind, :string)
    field(:price_tolerance, :decimal)
    has_many(:exceptions, MatchException, foreign_key: :match_line_id)
  end

  @doc "The fields a match line shows, besides its exceptions."
  def fields do
    [
      :line_number,
      :order_line_id,
      :order_number,
      :billed_quantity,
      :billed_unit_price,
      :previously_billed_quantity,
      :ordered_quantity,
      :ordered_unit_price,
      :received_quantity,
      :quantity_tolerance_kind,
      :quantity_tolerance,
      :price_tolerance_kind,
      :price_tolerance
    ]
  end
end
