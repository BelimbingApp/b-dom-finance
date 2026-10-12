defmodule Bilimbi.Finance.Receivables.DocumentLine do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The columns are numeric(20, 4): sixteen digits before the point.
  @amount_limit Decimal.new("1E16")

  schema "finance_receivables_document_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:line_number, :integer)
    field(:description, :string)
    field(:quantity, :decimal)
    field(:unit_price, :decimal)
    field(:amount, :decimal)
    field(:account_id, :integer)
    field(:tax_code_id, :integer)
    field(:tax_rate, :decimal)
    field(:tax_amount, :decimal)
  end

  @doc """
  Casts one document line. Quantity and unit price take up to four decimal
  places; anything finer is refused rather than rounded. `default_account_id`
  is the setup's income account, used when the line names none.
  """
  def changeset(line, attributes, default_account_id) do
    line
    |> cast(attributes, [:description, :quantity, :unit_price, :account_id, :tax_code_id])
    |> update_change(:description, &String.trim/1)
    |> put_default(:account_id, default_account_id)
    |> validate_required([:description, :quantity, :unit_price, :account_id])
    |> validate_length(:description, min: 1, max: 500)
    |> validate_number(:quantity, greater_than: 0, less_than: @amount_limit)
    |> validate_number(:unit_price, greater_than_or_equal_to: 0, less_than: @amount_limit)
    |> validate_scale(:quantity)
    |> validate_scale(:unit_price)
  end

  @doc """
  The line's amount, quantity times unit price rounded half up to the
  book's minor units, and its tax at `rate` percent (nil for no tax code),
  rounded the same way. Rounding is per line, so a document's tax is the
  sum of its lines' tax.
  """
  def put_amounts(changeset, minor_units, rate) do
    if changeset.valid? do
      amount =
        changeset
        |> get_field(:quantity)
        |> Decimal.mult(get_field(changeset, :unit_price))
        |> Decimal.round(minor_units, :half_up)

      tax =
        if rate,
          do:
            amount
            |> Decimal.mult(rate)
            |> Decimal.div(100)
            |> Decimal.round(minor_units, :half_up),
          else: Decimal.new(0)

      changeset
      |> put_change(:amount, amount)
      |> put_change(:tax_rate, rate)
      |> put_change(:tax_amount, tax)
      |> validate_number(:amount, less_than: @amount_limit)
    else
      changeset
    end
  end

  defp put_default(changeset, field, value) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, value),
      else: changeset
  end

  defp validate_scale(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Decimal.equal?(Decimal.round(value, 4), value),
        do: [],
        else: [{field, "has more than 4 decimal places"}]
    end)
  end
end
