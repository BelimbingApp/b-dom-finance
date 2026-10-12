defmodule Bilimbi.Finance.Receivables.LedgerAccounts do
  @moduledoc false
  # The company's chart, read through the ledger facade: receivables never
  # reads the ledger's tables, so the caller also needs finance.ledger.view.

  alias Bilimbi.Finance.Ledger
  alias Ecto.Changeset

  def fetch(scope, company_id) do
    with {:ok, accounts} <- Ledger.list_accounts(scope, company_id) do
      {:ok, Map.new(accounts, &{&1.id, &1})}
    end
  end

  @doc "Adds an error to `field` unless it names an active account of `type`."
  def validate(changeset, accounts, field, type) do
    case Changeset.get_field(changeset, field) do
      nil ->
        changeset

      id ->
        case problem(accounts, id, type) do
          nil -> changeset
          message -> Changeset.add_error(changeset, field, message)
        end
    end
  end

  def problem(accounts, id, type) do
    case Map.get(accounts, id) do
      nil -> "is not a ledger account of this company"
      %{active: false} -> "is an inactive ledger account"
      %{account_type: ^type} -> nil
      %{} -> "must be a ledger #{type} account"
    end
  end
end
