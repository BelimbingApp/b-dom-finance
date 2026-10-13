defmodule Bilimbi.Finance.Reconciliation.BankAccounts do
  @moduledoc false
  # A company's bank accounts, each mapped to one ledger account, with the
  # history of changes to them. The facade authorizes every call and holds
  # the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation.{BankAccount, BankAccountChange, Records}
  alias Ecto.Changeset

  def list(scope, company_id) do
    BankAccount
    |> Records.query(scope, company_id)
    |> order_by([a], asc: a.name)
    |> Repo.all()
  end

  def get(scope, company_id, bank_account_id),
    do: Records.get(BankAccount, scope, company_id, bank_account_id)

  @doc """
  Adds a bank account: `name`, `ledger_account_id` (an active asset account
  no other bank account maps), `import_mapping`, and optionally
  `charges_account_id` (an expense account), `interest_account_id` (an
  income account), `match_window_days`, and `active`. The chart is read
  through the ledger facade.
  """
  def create(scope, company_id, attributes) do
    with {:ok, accounts} <- chart(scope, company_id) do
      %BankAccount{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> BankAccount.create_changeset(attributes)
      |> validate_account(accounts, :ledger_account_id, "asset")
      |> validate_counter_accounts(accounts)
      |> Repo.insert()
      |> case do
        {:ok, account} ->
          first_values =
            account
            |> Map.take(BankAccount.changeable())
            |> Enum.reject(fn {_field, value} -> is_nil(value) end)
            |> Map.new()

          log_changes(scope, company_id, account, %{changes: first_values}, nil, attributes)
          {:ok, view(account)}

        error ->
          error
      end
    end
  end

  @doc "Changes a bank account's `name`, counter accounts, `match_window_days`, `import_mapping`, or `active`, with an optional `reason`."
  def update(scope, company_id, account, attributes) do
    with {:ok, accounts} <- chart(scope, company_id) do
      changeset =
        account
        |> BankAccount.update_changeset(attributes)
        |> validate_counter_accounts(accounts)

      with {:ok, updated} <- Repo.update(changeset) do
        log_changes(scope, company_id, updated, changeset, account, attributes)
        {:ok, view(updated)}
      end
    end
  end

  defp chart(scope, company_id) do
    with {:ok, accounts} <- Ledger.list_accounts(scope, company_id) do
      {:ok, Map.new(accounts, &{&1.id, &1})}
    end
  end

  defp validate_counter_accounts(changeset, accounts) do
    changeset
    |> validate_account(accounts, :charges_account_id, "expense")
    |> validate_account(accounts, :interest_account_id, "income")
  end

  defp validate_account(changeset, accounts, field, type) do
    case Changeset.get_change(changeset, field) do
      nil ->
        changeset

      id ->
        case Map.get(accounts, id) do
          nil ->
            Changeset.add_error(changeset, field, "is not a ledger account of this company")

          %{active: false} ->
            Changeset.add_error(changeset, field, "is an inactive ledger account")

          %{account_type: ^type} ->
            changeset

          %{} ->
            Changeset.add_error(changeset, field, "must be a ledger #{type} account")
        end
    end
  end

  # Every field set or changed is logged with who did it and why; a new
  # account's first values are logged with no old value.
  defp log_changes(scope, company_id, account, changeset, before, attributes) do
    {user_id, impersonator_id} = Records.actor_ids(scope)
    reason = reason(attributes)

    for field <- BankAccount.changeable(), Map.has_key?(changeset.changes, field) do
      Repo.insert!(%BankAccountChange{
        tenant_id: account.tenant_id,
        company_id: company_id,
        bank_account_id: account.id,
        field: Atom.to_string(field),
        old_value: before && text(Map.fetch!(before, field)),
        new_value: text(Map.fetch!(changeset.changes, field)),
        reason: reason,
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      })
    end
  end

  defp reason(attributes) do
    case Records.fetch(attributes, :reason) do
      text when is_binary(text) -> text |> String.trim() |> String.slice(0, 500) |> blank_to_nil()
      _none -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp text(nil), do: nil
  defp text(value) when is_map(value), do: value |> Enum.sort() |> inspect(limit: :infinity)
  defp text(value), do: to_string(value)

  def list_changes(scope, company_id, bank_account_id, options) do
    with {:ok, limit, cursor} <- Records.page_options(options) do
      changes =
        BankAccountChange
        |> Records.query(scope, company_id)
        |> where([c], c.bank_account_id == ^bank_account_id)
        |> Records.page(limit, cursor)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :field,
            :old_value,
            :new_value,
            :reason,
            :changed_by_user_id,
            :changed_by_impersonator_id,
            :changed_at
          ])
        )

      {:ok, changes}
    end
  end

  def view(%BankAccount{} = account) do
    Map.take(account, [
      :id,
      :name,
      :ledger_account_id,
      :charges_account_id,
      :interest_account_id,
      :match_window_days,
      :import_mapping,
      :active
    ])
  end
end
