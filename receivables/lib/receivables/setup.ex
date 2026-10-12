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

  @accounts [:receivable_account_id, :income_account_id]

  @doc "The setup's account fields, each logged when set or changed."
  def accounts, do: @accounts

  def changeset(setup, attributes) do
    setup
    |> cast(attributes, @accounts)
    |> validate_required([
      :tenant_id,
      :company_id,
      :receivable_account_id,
      :income_account_id
    ])
    |> unique_constraint(:company_id, name: :finance_receivables_setups_company_unique)
  end
end
