defmodule Bilimbi.Finance.Ledger.Line do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The column is numeric(20, 4): sixteen digits before the point.
  @amount_limit Decimal.new("1E16")

  schema "finance_ledger_entry_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:entry_id, :integer)
    field(:line_number, :integer)
    field(:account_id, :integer)
    field(:debit, :decimal)
    field(:credit, :decimal)
    field(:description, :string)
  end

  @doc """
  Casts one line of a journal entry. `minor_units` is the book currency's
  number of decimal places; an amount finer than that is refused rather than
  rounded, because PostgreSQL would otherwise round it silently.
  """
  def changeset(line, attributes, minor_units) do
    line
    |> cast(attributes, [:account_id, :debit, :credit, :description])
    |> update_change(:description, &String.trim/1)
    |> put_zero(:debit)
    |> put_zero(:credit)
    |> validate_required([:account_id])
    |> validate_number(:debit, greater_than_or_equal_to: 0, less_than: @amount_limit)
    |> validate_number(:credit, greater_than_or_equal_to: 0, less_than: @amount_limit)
    |> validate_amount_scale(:debit, minor_units)
    |> validate_amount_scale(:credit, minor_units)
    |> validate_one_side()
    |> validate_length(:description, max: 500)
  end

  defp put_zero(changeset, field) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, Decimal.new(0)),
      else: changeset
  end

  defp validate_amount_scale(changeset, field, minor_units) do
    validate_change(changeset, field, fn ^field, amount ->
      if Decimal.equal?(Decimal.round(amount, minor_units), amount),
        do: [],
        else: [{field, "has more than #{minor_units} decimal places"}]
    end)
  end

  defp validate_one_side(changeset) do
    debit = get_field(changeset, :debit)
    credit = get_field(changeset, :credit)

    if Decimal.gt?(debit, 0) != Decimal.gt?(credit, 0),
      do: changeset,
      else: add_error(changeset, :debit, "a line has either a debit or a credit")
  end
end
