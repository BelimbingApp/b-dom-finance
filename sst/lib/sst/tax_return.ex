defmodule Bilimbi.Finance.Sst.TaxReturn do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Sst.{Adjustment, ReturnEvent, Text}

  # The database numbers and stamps a return (see the migration).
  schema "finance_sst_returns" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:return_number, :integer, read_after_writes: true)
    field(:tax_type, :string)
    field(:registration_id, :integer)
    field(:period_start, :date)
    field(:period_end, :date)
    field(:due_date, :date)
    field(:amends_return_id, :integer)
    field(:reason, :string)
    field(:opened_by_user_id, :integer)
    field(:opened_by_impersonator_id, :integer)
    field(:opened_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:events, ReturnEvent, foreign_key: :return_id)
    has_many(:adjustments, Adjustment, foreign_key: :return_id)
  end

  def changeset(tax_return, attributes) do
    tax_return
    |> cast(attributes, [:reason])
    |> update_change(:reason, &Text.blank_to_nil/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :tax_type,
      :registration_id,
      :period_start,
      :period_end,
      :due_date,
      :opened_by_user_id
    ])
    |> validate_length(:reason, max: 500)
    |> validate_amendment_reason()
  end

  defp validate_amendment_reason(changeset) do
    if get_field(changeset, :amends_return_id) && is_nil(get_field(changeset, :reason)),
      do: add_error(changeset, :reason, "is needed to amend a finalised return"),
      else: changeset
  end
end
