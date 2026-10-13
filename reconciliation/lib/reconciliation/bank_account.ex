defmodule Bilimbi.Finance.Reconciliation.BankAccount do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Reconciliation.Mapping

  schema "finance_reconciliation_bank_accounts" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:name, :string)
    field(:ledger_account_id, :integer)
    field(:charges_account_id, :integer)
    field(:interest_account_id, :integer)
    field(:match_window_days, :integer, default: 5)
    field(:import_mapping, :map)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  @changeable [
    :name,
    :charges_account_id,
    :interest_account_id,
    :match_window_days,
    :import_mapping,
    :active
  ]

  @doc "The fields a change to an existing bank account is logged for."
  def changeable, do: @changeable

  def create_changeset(account, attributes) do
    account
    |> cast(attributes, [:ledger_account_id | @changeable])
    |> validate_required([:tenant_id, :company_id, :name, :ledger_account_id, :import_mapping])
    |> common()
    |> unique_constraint(:ledger_account_id,
      name: :finance_reconciliation_bank_accounts_ledger_account_unique,
      message: "already has a bank account"
    )
  end

  def update_changeset(account, attributes) do
    account
    |> cast(attributes, @changeable)
    |> validate_required([:name, :import_mapping])
    |> common()
  end

  defp common(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_number(:match_window_days, greater_than_or_equal_to: 0, less_than_or_equal_to: 90)
    |> validate_mapping()
    |> unique_constraint(:name,
      name: :finance_reconciliation_bank_accounts_company_name_unique,
      message: "is already a bank account of this company"
    )
  end

  defp validate_mapping(changeset) do
    case get_change(changeset, :import_mapping) do
      nil ->
        changeset

      mapping ->
        case Mapping.normalize(mapping) do
          {:ok, normalized} -> put_change(changeset, :import_mapping, normalized)
          {:error, message} -> add_error(changeset, :import_mapping, message)
        end
    end
  end
end
