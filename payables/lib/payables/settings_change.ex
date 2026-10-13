defmodule Bilimbi.Finance.Payables.SettingsChange do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_payables_settings_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:old_payable_account_id, :integer)
    field(:new_payable_account_id, :integer)
    field(:old_quantity_tolerance_kind, :string)
    field(:new_quantity_tolerance_kind, :string)
    field(:old_quantity_tolerance, :decimal)
    field(:new_quantity_tolerance, :decimal)
    field(:old_price_tolerance_kind, :string)
    field(:new_price_tolerance_kind, :string)
    field(:old_price_tolerance, :decimal)
    field(:new_price_tolerance, :decimal)
    field(:reason, :string)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "The fields `list_settings_changes/2` shows."
  def fields do
    [
      :id,
      :old_payable_account_id,
      :new_payable_account_id,
      :old_quantity_tolerance_kind,
      :new_quantity_tolerance_kind,
      :old_quantity_tolerance,
      :new_quantity_tolerance,
      :old_price_tolerance_kind,
      :new_price_tolerance_kind,
      :old_price_tolerance,
      :new_price_tolerance,
      :reason,
      :changed_by_user_id,
      :changed_by_impersonator_id,
      :changed_at
    ]
  end

  def changeset(change, attributes) do
    change
    |> cast(attributes, [:reason])
    |> update_change(:reason, &blank_to_nil/1)
    |> validate_length(:reason, max: 500)
    |> validate_required([
      :tenant_id,
      :company_id,
      :new_payable_account_id,
      :changed_by_user_id
    ])
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
