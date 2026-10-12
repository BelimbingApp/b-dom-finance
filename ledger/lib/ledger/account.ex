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
    field(:retained_earnings, :boolean, default: false)
    timestamps(type: :naive_datetime)
  end

  @doc "The five account types every chart of accounts classifies by."
  def types, do: @types

  def create_changeset(account, attributes) do
    account
    |> cast(attributes, [:code, :name, :account_type, :parent_id, :active, :retained_earnings])
    |> update_change(:code, &String.trim/1)
    |> update_change(:account_type, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code, :account_type])
    |> validate_length(:code, min: 1, max: 50)
    |> validate_inclusion(:account_type, @types)
    |> details()
    |> unique_constraint(:code, name: :finance_ledger_accounts_company_code_unique)
  end

  # Code and type are the account's identity: entries were posted against
  # them, so only the descriptive, grouping, and designation fields change.
  def update_changeset(account, attributes) do
    account
    |> cast(attributes, [:name, :parent_id, :active, :retained_earnings])
    |> details()
  end

  defp details(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :active, :retained_earnings])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_retained_earnings()
    |> foreign_key_constraint(:parent_id, name: :finance_ledger_accounts_parent_fkey)
    |> check_constraint(:retained_earnings,
      name: :finance_ledger_accounts_retained_earnings_equity,
      message: "must be an equity account"
    )
    |> unique_constraint(:retained_earnings,
      name: :finance_ledger_accounts_one_retained_earnings,
      message: "is already another account"
    )
  end

  # The year-end close moves profit into the one equity account a company
  # designates for retained earnings.
  defp validate_retained_earnings(changeset) do
    if get_field(changeset, :retained_earnings) == true and
         get_field(changeset, :account_type) != "equity",
       do: add_error(changeset, :retained_earnings, "must be an equity account"),
       else: changeset
  end
end
