defmodule Bilimbi.Finance.Payables.Settings do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Payables.Amount

  @tolerance_kinds ~w(percent amount)

  schema "finance_payables_settings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:payable_account_id, :integer)
    # Three-way match tolerances: each a percentage of the ordered figure or
    # an amount in its unit, and none means an exact match.
    field(:quantity_tolerance_kind, :string)
    field(:quantity_tolerance, :decimal)
    field(:price_tolerance_kind, :string)
    field(:price_tolerance, :decimal)
    timestamps(type: :naive_datetime)
  end

  @doc "The tolerance kinds: a percentage of the ordered figure, or an amount in its unit."
  def tolerance_kinds, do: @tolerance_kinds

  @doc "The fields the tolerances are made of, as `put_settings/3` takes and shows them."
  def tolerance_fields,
    do: [:quantity_tolerance_kind, :quantity_tolerance, :price_tolerance_kind, :price_tolerance]

  def changeset(settings, attributes) do
    settings
    |> cast(attributes, [:payable_account_id | tolerance_fields()])
    |> validate_required([:tenant_id, :company_id, :payable_account_id])
    |> validate_tolerance(:quantity_tolerance_kind, :quantity_tolerance)
    |> validate_tolerance(:price_tolerance_kind, :price_tolerance)
    |> unique_constraint(:company_id, name: :finance_payables_settings_company_unique)
  end

  defp validate_tolerance(changeset, kind_field, value_field) do
    changeset
    |> validate_inclusion(kind_field, @tolerance_kinds)
    |> Amount.validate(value_field, 4, :non_negative)
    |> then(fn changeset ->
      case {get_field(changeset, kind_field), get_field(changeset, value_field)} do
        {nil, nil} -> changeset
        {nil, _value} -> add_error(changeset, kind_field, "is needed with a tolerance")
        {_kind, nil} -> add_error(changeset, value_field, "is needed with a tolerance kind")
        _both -> changeset
      end
    end)
  end
end
