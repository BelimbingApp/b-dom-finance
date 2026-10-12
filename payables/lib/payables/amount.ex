defmodule Bilimbi.Finance.Payables.Amount do
  @moduledoc false
  import Ecto.Changeset

  # Amount columns are numeric(20, 4): sixteen digits before the point.
  @limit Decimal.new("1E16")

  @doc """
  Validates a money field: at least `min` (`:positive` or `:non_negative`),
  under the column's limit, and no finer than the book's `minor_units`. A
  finer amount is refused rather than rounded, because PostgreSQL would
  otherwise round it silently.
  """
  def validate(changeset, field, minor_units, min \\ :positive) do
    changeset
    |> then(fn changeset ->
      case min do
        :positive ->
          validate_number(changeset, field, greater_than: 0, less_than: @limit)

        :non_negative ->
          validate_number(changeset, field, greater_than_or_equal_to: 0, less_than: @limit)
      end
    end)
    |> validate_change(field, fn ^field, amount ->
      if Decimal.equal?(Decimal.round(amount, minor_units), amount),
        do: [],
        else: [{field, "has more than #{minor_units} decimal places"}]
    end)
  end

  @doc "Rounds half up to the book's minor units."
  def round(amount, minor_units), do: Decimal.round(amount, minor_units, :half_up)

  @doc "The sum of a field over maps or changesets."
  def sum(items, field) do
    Enum.reduce(items, Decimal.new(0), fn
      %Ecto.Changeset{} = item, total -> Decimal.add(get_field(item, field) || 0, total)
      item, total -> Decimal.add(Map.fetch!(item, field), total)
    end)
  end
end
