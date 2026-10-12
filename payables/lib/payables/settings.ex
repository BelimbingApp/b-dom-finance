defmodule Bilimbi.Finance.Payables.Settings do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_payables_settings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:payable_account_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(settings, attributes) do
    settings
    |> cast(attributes, [:payable_account_id])
    |> validate_required([:tenant_id, :company_id, :payable_account_id])
    |> unique_constraint(:company_id, name: :finance_payables_settings_company_unique)
  end
end
