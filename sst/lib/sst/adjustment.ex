defmodule Bilimbi.Finance.Sst.Adjustment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Sst.Text

  # The column is numeric(20, 4): sixteen digits before the point.
  @amount_limit Decimal.new("1E16")

  # The database numbers and stamps an adjustment (see the migration).
  schema "finance_sst_return_adjustments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:adjustment_number, :integer, read_after_writes: true)
    field(:return_id, :integer)
    field(:action, :string)
    field(:withdraws_adjustment_id, :integer)
    field(:copied_from_adjustment_id, :integer)
    field(:box, :string)
    field(:taxable_amount, :decimal)
    field(:tax_amount, :decimal)
    field(:description, :string)
    field(:reference, :string)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "An adjustment added to `box`, which takes the `columns` given."
  def add_changeset(adjustment, attributes, columns, minor_units) do
    adjustment
    |> cast(attributes, [:taxable_amount, :tax_amount, :description, :reference])
    |> default_absent(:taxable_amount, columns)
    |> default_absent(:tax_amount, columns)
    |> update_change(:description, &Text.blank_to_nil/1)
    |> update_change(:reference, &Text.blank_to_nil/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :return_id,
      :box,
      :taxable_amount,
      :tax_amount,
      :description,
      :recorded_by_user_id
    ])
    |> validate_amount(:taxable_amount, :taxable in columns, minor_units)
    |> validate_amount(:tax_amount, :tax in columns, minor_units)
    |> validate_something()
    |> validate_length(:description, max: 500)
    |> validate_length(:reference, max: 100)
  end

  @doc "A withdrawal of an added adjustment, with its reason as the description."
  def withdraw_changeset(adjustment, attributes) do
    adjustment
    |> cast(attributes, [:description])
    |> update_change(:description, &Text.blank_to_nil/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :return_id,
      :withdraws_adjustment_id,
      :description,
      :recorded_by_user_id
    ])
    |> validate_length(:description, max: 500)
  end

  # A column the box does not take is zero.
  defp default_absent(changeset, field, columns) do
    column = if field == :taxable_amount, do: :taxable, else: :tax

    if column in columns or not is_nil(get_change(changeset, field)),
      do: changeset,
      else: put_change(changeset, field, Decimal.new(0))
  end

  defp validate_amount(changeset, field, taken?, minor_units) do
    validate_change(changeset, field, fn ^field, amount ->
      cond do
        not taken? and not Decimal.equal?(amount, 0) ->
          [{field, "is not a column of this box"}]

        Decimal.negative?(amount) ->
          [{field, "must not be negative"}]

        Decimal.compare(amount, @amount_limit) != :lt ->
          [{field, "is too large"}]

        not Decimal.equal?(Decimal.round(amount, minor_units), amount) ->
          [{field, "has more than #{minor_units} decimal places"}]

        true ->
          []
      end
    end)
  end

  defp validate_something(changeset) do
    taxable = get_field(changeset, :taxable_amount)
    tax = get_field(changeset, :tax_amount)

    if taxable && tax && Decimal.equal?(taxable, 0) && Decimal.equal?(tax, 0),
      do: add_error(changeset, :tax_amount, "or the value must be above zero"),
      else: changeset
  end
end
