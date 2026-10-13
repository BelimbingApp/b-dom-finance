defmodule Bilimbi.Finance.Payroll.SettingsChange do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_payroll_settings_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:old_net_pay_account_id, :integer)
    field(:new_net_pay_account_id, :integer)
    field(:old_claims_payable_account_id, :integer)
    field(:new_claims_payable_account_id, :integer)
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
      :old_net_pay_account_id,
      :new_net_pay_account_id,
      :old_claims_payable_account_id,
      :new_claims_payable_account_id,
      :reason,
      :changed_by_user_id,
      :changed_by_impersonator_id,
      :changed_at
    ]
  end

  def changeset(change, attributes) do
    change
    |> cast(attributes, [:reason])
    |> update_change(:reason, &Bilimbi.Finance.Payroll.Reason.trim/1)
    |> validate_length(:reason, max: 500)
    |> validate_required([
      :tenant_id,
      :company_id,
      :new_net_pay_account_id,
      :new_claims_payable_account_id,
      :changed_by_user_id
    ])
  end
end
