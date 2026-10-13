defmodule Bilimbi.Finance.Ledger.Duties do
  @moduledoc false

  # Separation of duties for every Finance approval: the company's setting,
  # the same-person rule, and the approval exceptions log. The facade
  # authorizes and takes the company lock; these run inside its transaction.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope

  alias Bilimbi.Finance.Ledger.{
    ApprovalException,
    ApprovalExceptionReview,
    DutySeparationChange
  }

  alias Ecto.Changeset

  @doc "The company's latest duty separation change, or nil before any."
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

  @doc "Appends a change of the setting, or returns the latest when it changes nothing."
  def change(scope, company_id, attributes) do
    latest = latest_change(scope, company_id)
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    changeset =
      %DutySeparationChange{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      }
      |> DutySeparationChange.changeset(attributes)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      Changeset.get_field(changeset, :required) == DutySeparationChange.required?(latest) ->
        {:ok, latest}

      true ->
        Repo.insert(changeset)
    end
  end

  @doc """
  Decides whether the scope's actor may approve what `approval` describes,
  and records the approval exception when it is one: `{:ok, exception}`,
  or `{:ok, nil}` for an independent approval that is no override. See
  `Bilimbi.Finance.Ledger.check_approval/3`.
  """
  def check(scope, company_id, approval) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    approver = {user_id, impersonator_id}
    preparers = approval |> fetch(:prepared_by) |> List.wrap() |> Enum.map(&person/1)
    overlapping = Enum.find(preparers, &same_person?(&1, approver))
    override? = fetch(approval, :override) == true
    latest = latest_change(scope, company_id)

    cond do
      overlapping && DutySeparationChange.required?(latest) ->
        {:error, :same_person}

      overlapping || override? ->
        {prepared_user, prepared_impersonator} = overlapping || List.first(preparers, {nil, nil})

        %ApprovalException{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          same_person: overlapping != nil,
          override: override?,
          prepared_by_user_id: prepared_user,
          prepared_by_impersonator_id: prepared_impersonator,
          approved_by_user_id: user_id,
          approved_by_impersonator_id: impersonator_id,
          separation_change_id: overlapping && latest.id
        }
        |> ApprovalException.changeset(%{
          source: fetch(approval, :source),
          action: fetch(approval, :action),
          subject_type: fetch(approval, :subject_type),
          subject_id: fetch(approval, :subject_id),
          subject: fetch(approval, :subject),
          reason: if(override?, do: fetch(approval, :reason), else: latest.reason)
        })
        |> Repo.insert()

      true ->
        {:ok, nil}
    end
  end

  @doc "Whether two `{user_id, impersonator_id}` people overlap."
  def same_person?({user, impersonator}, {other_user, other_impersonator}) do
    mine = MapSet.new(Enum.reject([user, impersonator], &is_nil/1))
    theirs = MapSet.new(Enum.reject([other_user, other_impersonator], &is_nil/1))
    not MapSet.disjoint?(mine, theirs)
  end

  defp person(%{} = person), do: {fetch(person, :user_id), fetch(person, :impersonator_id)}
  defp person({user_id, impersonator_id}), do: {user_id, impersonator_id}
  defp person(_other), do: {nil, nil}

  ## Exceptions

  def exceptions(scope, company_id, filters) do
    scope
    |> exceptions_query(company_id)
    |> recorded_from(filters.recorded_from)
    |> recorded_before(filters.recorded_before)
    |> reviewed(scope, filters.reviewed)
    |> after_number(filters.after)
    |> order_by([x], asc: x.exception_number)
    |> limit(^filters.limit)
    |> preload(review: ^reviews_query(scope))
    |> Repo.all()
  end

  def exception(scope, company_id, exception_id) when is_integer(exception_id) do
    scope
    |> exceptions_query(company_id)
    |> where([x], x.id == ^exception_id)
    |> preload(review: ^reviews_query(scope))
    |> Repo.one()
  end

  def exception(_scope, _company_id, _exception_id), do: nil

  @doc "Appends an independent review of an exception."
  def review(scope, company_id, exception, attributes) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    reviewer = {user_id, impersonator_id}

    cond do
      exception.review ->
        {:error, :already_reviewed}

      same_person?(
        reviewer,
        {exception.approved_by_user_id, exception.approved_by_impersonator_id}
      ) or
          same_person?(
            reviewer,
            {exception.prepared_by_user_id, exception.prepared_by_impersonator_id}
          ) ->
        {:error, :reviewer_not_independent}

      true ->
        %ApprovalExceptionReview{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          exception_id: exception.id,
          reviewed_by_user_id: user_id,
          reviewed_by_impersonator_id: impersonator_id
        }
        |> ApprovalExceptionReview.changeset(attributes)
        |> Repo.insert()
    end
  end

  defp recorded_from(query, nil), do: query
  defp recorded_from(query, from), do: where(query, [x], x.recorded_at >= ^from)

  defp recorded_before(query, nil), do: query
  defp recorded_before(query, before), do: where(query, [x], x.recorded_at < ^before)

  defp reviewed(query, _scope, nil), do: query

  defp reviewed(query, scope, reviewed?) do
    reviewed_ids = select(reviews_query(scope), [r], r.exception_id)

    if reviewed?,
      do: where(query, [x], x.id in subquery(reviewed_ids)),
      else: where(query, [x], x.id not in subquery(reviewed_ids))
  end

  defp after_number(query, nil), do: query
  defp after_number(query, number), do: where(query, [x], x.exception_number > ^number)

  defp changes_query(scope, company_id),
    do: where(Tenancy.scope_query(DutySeparationChange, scope), [c], c.company_id == ^company_id)

  defp exceptions_query(scope, company_id),
    do: where(Tenancy.scope_query(ApprovalException, scope), [x], x.company_id == ^company_id)

  defp reviews_query(scope), do: Tenancy.scope_query(ApprovalExceptionReview, scope)

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))
end
