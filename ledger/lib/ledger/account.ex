defmodule Bilimbi.Finance.Ledger.Account do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(asset liability equity income expense)

  schema "finance_ledger_accounts" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:account_type, :string)
    field(:parent_id, :integer)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  @doc "The five account types every chart of accounts classifies by."
  def types, do: @types

  def create_changeset(account, attributes) do
    account
    |> cast(attributes, [:code, :name, :account_type, :parent_id, :active])
    |> update_change(:code, &String.trim/1)
    |> update_change(:account_type, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code, :account_type])
    |> validate_length(:code, min: 1, max: 50)
    |> validate_inclusion(:account_type, @types)
    |> details()
    |> unique_constraint(:code, name: :finance_ledger_accounts_company_code_unique)
  end

  # Code and type are the account's identity: entries were posted against
  # them, so only the descriptive and grouping fields change.
  def update_changeset(account, attributes) do
    account
    |> cast(attributes, [:name, :parent_id, :active])
    |> details()
  end

  defp details(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :active])
    |> validate_length(:name, min: 1, max: 200)
    |> foreign_key_constraint(:parent_id, name: :finance_ledger_accounts_parent_fkey)
  end
end
