defmodule Bilimbi.Finance.Payroll.Settings do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_payroll_settings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The liability a run's net pay is owed on until paid.
    field(:net_pay_account_id, :integer)
    # The liability an approved claim is owed on until reimbursed.
    field(:claims_payable_account_id, :integer)
    timestamps(type: :naive_datetime)
  end

  @doc "The account fields, as `put_settings/3` takes and shows them."
  def account_fields, do: [:net_pay_account_id, :claims_payable_account_id]

  def changeset(settings, attributes) do
    settings
    |> cast(attributes, account_fields())
    |> validate_required([:tenant_id, :company_id | account_fields()])
    |> unique_constraint(:company_id, name: :finance_payroll_settings_company_unique)
  end
end
