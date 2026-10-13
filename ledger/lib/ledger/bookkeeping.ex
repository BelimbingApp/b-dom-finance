defmodule Bilimbi.Finance.Ledger.Bookkeeping do
  @moduledoc false

  # Controlled bookkeeping: the company's setting and its append-only history.
  # The facade authorizes and takes the company lock; these run inside its
  # transaction.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger.BookkeepingChange
  alias Ecto.Changeset

  @doc "The company's latest change, or nil before any."
  def latest_change(scope, company_id) do
    scope
    |> changes_query(company_id)
    |> order_by([c], desc: c.change_number)
    |> limit(1)
    |> Repo.one()
  end

  def changes(scope, company_id) do
    scope
    |> changes_query(company_id)
    |> order_by([c], asc: c.change_number)
    |> Repo.all()
  end

  @doc "Whether the company is controlled by its latest change."
  def controlled?(scope, company_id) do
    scope
    |> latest_change(company_id)
    |> BookkeepingChange.controlled?()
  end

  @doc """
  Appends a change of the setting. `{:ok, change, :recorded}` when it changed
  the setting, `{:ok, latest, :unchanged}` when it changed nothing, which
  records nothing.
  """
  def change(scope, company_id, attributes) do
    latest = latest_change(scope, company_id)
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    changeset =
      %BookkeepingChange{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      }
      |> BookkeepingChange.changeset(attributes)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      Changeset.get_field(changeset, :controlled) == BookkeepingChange.controlled?(latest) ->
        {:ok, latest, :unchanged}

      true ->
        with {:ok, change} <- Repo.insert(changeset), do: {:ok, change, :recorded}
    end
  end

  defp changes_query(scope, company_id),
    do:
      where(
        Tenancy.scope_query(BookkeepingChange, scope),
        [c],
        c.company_id == ^company_id
      )
end
