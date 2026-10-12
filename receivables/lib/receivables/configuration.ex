defmodule Bilimbi.Finance.Receivables.Configuration do
  @moduledoc false
  # A company's receivables setup, document series, and tax codes. The
  # facade authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger

  alias Bilimbi.Finance.Receivables.{
    LedgerAccounts,
    Records,
    Series,
    Setup,
    SetupChange,
    TaxCode
  }

  @doc """
  What every document and payment write needs: the ledger book (its
  currency and minor units), the receivables setup, and the chart of
  accounts by ID.
  """
  def context(scope, company_id) do
    with {:ok, book} <- Ledger.get_book(scope, company_id),
         {:ok, setup} <- configured_setup(scope, company_id),
         {:ok, accounts} <- LedgerAccounts.fetch(scope, company_id) do
      {:ok, %{book: book, setup: setup, accounts: accounts}}
    end
  end

  defp configured_setup(scope, company_id) do
    case setup(scope, company_id) do
      nil -> {:error, :not_configured}
      setup -> {:ok, setup}
    end
  end

  ## Setup

  def setup(scope, company_id) do
    Repo.one(Records.query(Setup, scope, company_id))
  end

  # Documents and payments post to the accounts they recorded, so a new
  # setup account only reaches later documents; every account set or
  # changed is logged with who changed it.
  def configure(scope, company_id, attributes) do
    with {:ok, accounts} <- LedgerAccounts.fetch(scope, company_id) do
      changeset =
        (setup(scope, company_id) ||
           %Setup{tenant_id: Scope.tenant_id(scope), company_id: company_id})
        |> Setup.changeset(attributes)
        |> LedgerAccounts.validate(accounts, :receivable_account_id, "asset")
        |> LedgerAccounts.validate(accounts, :income_account_id, "income")

      with {:ok, setup} <- Repo.insert_or_update(changeset) do
        log_changes(scope, changeset)
        {:ok, setup_view(setup)}
      end
    end
  end

  defp log_changes(scope, changeset) do
    {user_id, impersonator_id} = Records.actor_ids(scope)

    for field <- Setup.accounts(), Map.has_key?(changeset.changes, field) do
      Repo.insert!(%SetupChange{
        tenant_id: changeset.data.tenant_id,
        company_id: changeset.data.company_id,
        field: Atom.to_string(field),
        old_value: Map.fetch!(changeset.data, field),
        new_value: Map.fetch!(changeset.changes, field),
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      })
    end
  end

  def list_setup_changes(scope, company_id, options) do
    with {:ok, limit, cursor} <- Records.page_options(options) do
      changes =
        Records.query(SetupChange, scope, company_id)
        |> Records.page(limit, cursor)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :field,
            :old_value,
            :new_value,
            :changed_by_user_id,
            :changed_by_impersonator_id,
            :changed_at
          ])
        )

      {:ok, changes}
    end
  end

  def setup_view(setup),
    do: Map.take(setup, [:company_id, :receivable_account_id, :income_account_id])

  ## Series

  def list_series(scope, company_id) do
    Records.query(Series, scope, company_id)
    |> order_by([s], asc: s.code)
    |> Repo.all()
    |> Enum.map(&series_view/1)
  end

  def create_series(scope, company_id, attributes) do
    %Series{tenant_id: Scope.tenant_id(scope), company_id: company_id}
    |> Series.create_changeset(attributes)
    |> Repo.insert()
    |> view(&series_view/1)
  end

  def update_series(scope, company_id, series_id, attributes) do
    case Records.get(Series, scope, company_id, series_id) do
      nil ->
        {:error, :series_not_found}

      series ->
        series |> Series.update_changeset(attributes) |> Repo.update() |> view(&series_view/1)
    end
  end

  def series_view(series),
    do: Map.take(series, [:id, :code, :name, :kind, :prefix, :number_width, :active])

  ## Tax codes

  def list_tax_codes(scope, company_id) do
    Records.query(TaxCode, scope, company_id)
    |> order_by([t], asc: t.code)
    |> Repo.all()
    |> Enum.map(&tax_code_view/1)
  end

  def create_tax_code(scope, company_id, attributes) do
    with {:ok, accounts} <- LedgerAccounts.fetch(scope, company_id) do
      %TaxCode{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> TaxCode.create_changeset(attributes)
      |> LedgerAccounts.validate(accounts, :account_id, "liability")
      |> Repo.insert()
      |> view(&tax_code_view/1)
    end
  end

  def update_tax_code(scope, company_id, tax_code_id, attributes) do
    with {:ok, accounts} <- LedgerAccounts.fetch(scope, company_id) do
      case Records.get(TaxCode, scope, company_id, tax_code_id) do
        nil ->
          {:error, :tax_code_not_found}

        tax_code ->
          tax_code
          |> TaxCode.update_changeset(attributes)
          |> validate_changed_account(accounts)
          |> Repo.update()
          |> view(&tax_code_view/1)
      end
    end
  end

  # An unchanged account was checked when it was set; only a new one is.
  defp validate_changed_account(changeset, accounts) do
    if Map.has_key?(changeset.changes, :account_id),
      do: LedgerAccounts.validate(changeset, accounts, :account_id, "liability"),
      else: changeset
  end

  def tax_code_view(tax_code),
    do: Map.take(tax_code, [:id, :code, :name, :rate, :account_id, :active])

  defp view({:ok, record}, view), do: {:ok, view.(record)}
  defp view(error, _view), do: error
end
