defmodule Bilimbi.Finance.Payables.TaxCodeChange do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_payables_tax_code_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:tax_code_id, :integer)
    field(:old_name, :string)
    field(:new_name, :string)
    field(:old_rate, :decimal)
    field(:new_rate, :decimal)
    field(:old_account_id, :integer)
    field(:new_account_id, :integer)
    field(:old_active, :boolean)
    field(:new_active, :boolean)
    field(:reason, :string)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(change, attributes) do
    change
    |> cast(attributes, [:reason])
    |> update_change(:reason, &blank_to_nil/1)
    |> validate_length(:reason, max: 500)
    |> validate_required([
      :tenant_id,
      :company_id,
      :tax_code_id,
      :new_name,
      :new_rate,
      :new_account_id,
      :new_active,
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
