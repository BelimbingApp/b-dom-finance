defmodule Bilimbi.Finance.Einvoice.Draft.Line do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:description, :string)
    field(:classification_code, :string)
    field(:tariff_code, :string)
    field(:origin_country_code, :string)
    field(:quantity, :decimal)
    field(:unit_code, :string)
    field(:unit_price, :decimal)
    field(:discount_amount, :decimal, default: Decimal.new(0))
    field(:charge_amount, :decimal, default: Decimal.new(0))
    field(:tax_type, :string)
    field(:tax_rate, :decimal)
    field(:tax_exemption_reason, :string)
    # Derived from the fields above (see `Draft`).
    field(:subtotal, :decimal)
    field(:line_extension_amount, :decimal)
    field(:tax_amount, :decimal)
  end

  @max_amount Decimal.new("999999999999999999.99")

  # `source_tax?`: the line carries its tax, the sum of a consolidated
  # document's sources' tax, instead of deriving it from the rate.
  def changeset(line, attributes, source_tax? \\ false) do
    line
    |> cast(
      attributes,
      [
        :description,
        :classification_code,
        :tariff_code,
        :origin_country_code,
        :quantity,
        :unit_code,
        :unit_price,
        :discount_amount,
        :charge_amount,
        :tax_type,
        :tax_rate,
        :tax_exemption_reason
      ] ++ if(source_tax?, do: [:tax_amount], else: [])
    )
    |> blank_is_zero(:discount_amount)
    |> blank_is_zero(:charge_amount)
    |> validate_required([
      :description,
      :classification_code,
      :quantity,
      :unit_price,
      :tax_type,
      :tax_rate
    ])
    |> validate_length(:description, max: 300)
    |> validate_length(:tariff_code, max: 32)
    |> validate_length(:tax_exemption_reason, max: 300)
    |> validate_number(:quantity, greater_than: 0, less_than: @max_amount)
    |> validate_number(:unit_price, greater_than_or_equal_to: 0, less_than: @max_amount)
    |> validate_number(:discount_amount, greater_than_or_equal_to: 0, less_than: @max_amount)
    |> validate_number(:charge_amount, greater_than_or_equal_to: 0, less_than: @max_amount)
    |> validate_number(:tax_rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_scale(:quantity, 6)
    |> validate_scale(:unit_price, 6)
    |> validate_scale(:discount_amount, 2)
    |> validate_scale(:charge_amount, 2)
    |> validate_scale(:tax_rate, 4)
    |> validate_source_tax(source_tax?)
    |> derive_amounts(source_tax?)
  end

  defp validate_source_tax(changeset, false), do: changeset

  defp validate_source_tax(changeset, true) do
    changeset
    |> validate_required([:tax_amount])
    |> validate_number(:tax_amount, greater_than_or_equal_to: 0, less_than: @max_amount)
    |> validate_scale(:tax_amount, 2)
  end

  # A blank discount or charge is none; a blank tax rate is refused, never zero.
  defp blank_is_zero(changeset, field) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, Decimal.new(0)),
      else: changeset
  end

  # Amounts are refused, not rounded, when finer than their column.
  defp validate_scale(changeset, field, places) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(value, Decimal.round(value, places)),
        do: [],
        else: [{field, "has more than #{places} decimal places"}]
    end)
  end

  # subtotal = quantity x unit price; line amount = subtotal - discount +
  # charge; tax = line amount x rate. Each rounds half up to two places.
  defp derive_amounts(%{valid?: false} = changeset, _source_tax?), do: changeset

  defp derive_amounts(changeset, source_tax?) do
    quantity = get_field(changeset, :quantity)
    subtotal = money(Decimal.mult(quantity, get_field(changeset, :unit_price)))

    line_amount =
      subtotal
      |> Decimal.sub(get_field(changeset, :discount_amount))
      |> Decimal.add(get_field(changeset, :charge_amount))

    tax =
      if source_tax?,
        do: get_field(changeset, :tax_amount),
        else: money(Decimal.div(Decimal.mult(line_amount, get_field(changeset, :tax_rate)), 100))

    changeset =
      changeset
      |> put_change(:subtotal, subtotal)
      |> put_change(:line_extension_amount, line_amount)
      |> put_change(:tax_amount, tax)

    cond do
      Decimal.negative?(line_amount) ->
        add_error(changeset, :discount_amount, "exceeds the line's amount")

      Decimal.compare(line_amount, @max_amount) == :gt ->
        add_error(changeset, :quantity, "makes the line amount too large")

      true ->
        changeset
    end
  end

  defp money(value), do: Decimal.round(value, 2, :half_up)
end
