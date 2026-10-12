defmodule Bilimbi.Finance.Receivables.Setup do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_receivables_setups" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:receivable_account_id, :integer)
    field(:income_account_id, :integer)
    timestamps(type: :naive_datetime)
  end

  def changeset(setup, attributes) do
    setup
    |> cast(attributes, [:receivable_account_id, :income_account_id])
    |> validate_required([
      :tenant_id,
      :company_id,
      :receivable_account_id,
      :income_account_id
    ])
    |> unique_constraint(:company_id, name: :finance_receivables_setups_company_unique)
  end
end
